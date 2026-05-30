# 同步 Agent，异步外壳：Hermes Agent 的 Python 并发实践

大模型 Agent 的运行模式天然容易“卡住”：一次用户请求可能触发多轮模型调用、工具调用、终端命令、浏览器任务、代码执行、定时任务，甚至持续几分钟到几小时。Hermes Agent 的处理方式不是把所有代码都改成 `async def`，而是采用一种更工程化的混合模型：

```text
同步核心 + 异步调度 + 线程承载 + 进程管理 + 队列通信
```

这个设计很适合 Agent 系统。核心推理循环保持同步，逻辑简单；外层 Gateway、CLI、cron、process registry 则负责非阻塞交互、并发任务、中断、通知和恢复。

## 1. `asyncio`：让 Gateway 不被长任务阻塞

在消息平台里，用户发来一条消息后，系统不能等 Agent 跑完才继续接收后续消息。Hermes 的 Gateway 在收到消息时，会快速创建后台任务：

- `gateway/platforms/base.py`

```python
task = asyncio.create_task(self._process_message_background(event, session_key))
self._background_tasks.add(task)
task.add_done_callback(self._background_tasks.discard)
```

这就是典型的 `asyncio` 非阻塞调度：当前协程马上返回，真正耗时的处理交给后台 task。这样 Gateway 可以继续接收 `/stop`、`/queue`、`/approve`、新消息、平台事件等。

但这里有一个关键问题：同一个会话不能同时跑两个 Agent，否则会出现上下文错乱、重复回复、工具并发写文件等问题。Hermes 用 `asyncio.Event` 和 `_active_sessions` 做 session guard：

```python
self._active_sessions[session_key] = interrupt_event
```

如果新消息到来时该 session 正在运行，Hermes 不会再启动一个 Agent，而是把消息放进 pending，并设置 interrupt event。当前 Agent 感知中断后结束，后续消息再接着处理。

这体现了异步系统里的一个基本原则：异步不是无限并行，而是可控调度。

## 2. 同步核心：`AIAgent.run_conversation()` 为什么不直接 async

Hermes 的核心 Agent loop 在 `run_agent.py` 中，整体是同步循环：

```python
while api_call_count < self.max_iterations:
    response = client.chat.completions.create(...)
    if response.tool_calls:
        handle_function_call(...)
    else:
        return final_response
```

这个同步模型有好处：推理状态、消息列表、工具结果、重试逻辑、上下文压缩都在一个清晰的控制流里。

但 Gateway 不能直接在 event loop 里调用这个同步函数，否则整个事件循环会被阻塞。所以 Hermes 在 Gateway 侧把同步 Agent 丢进 executor 线程：

- `gateway/run.py`

```python
_executor_task = asyncio.ensure_future(
    self._run_in_executor_with_context(run_sync)
)
```

这就是常见的“async 外壳包同步核心”模式：

```python
async def handle_request():
    result = await loop.run_in_executor(None, blocking_agent_run)
```

Agent 仍然同步执行，但 Gateway 的 event loop 可以继续处理其他事件。

## 3. `threading.Thread`：CLI 后台任务和 stdout reader

CLI 的 `/background <prompt>` 是另一个典型例子。用户可以让 Hermes 在后台跑一个独立任务，同时继续当前聊天。CLI 里直接创建 daemon thread：

- `cli.py`

```python
thread = threading.Thread(
    target=run_background,
    daemon=True,
    name=f"bg-task-{task_id}",
)
thread.start()
```

这个后台线程会创建新的 `AIAgent`，使用独立 `session_id=task_id`，所以不会污染当前会话历史。

线程还大量用于后台进程输出读取。例如 `terminal(background=true)` 启动长进程后，Hermes 用 reader thread 持续读取 stdout：

- `tools/process_registry.py`

```python
reader = threading.Thread(
    target=self._reader_loop,
    args=(session,),
    daemon=True,
)
reader.start()
```

这是多线程非常适合的场景：I/O 等待多、共享状态少、需要持续监听。

## 4. `ThreadPoolExecutor`：cron 并发和 inactivity timeout

Hermes 的 cron 系统用于定时任务、提醒、周期性调研。任务存储在 `~/.hermes/cron/jobs.json`，输出写入 `~/.hermes/cron/output/...`。

Gateway 里会启动一个后台 cron ticker，每 60 秒 tick 一次：

- `gateway/run.py`

```python
cron_tick(verbose=False, adapters=adapters, loop=loop)
```

当有多个 due jobs 时，调度器使用 `ThreadPoolExecutor` 并行执行：

- `cron/scheduler.py`

```python
with concurrent.futures.ThreadPoolExecutor(max_workers=_max_workers) as pool:
    futures.append(pool.submit(_ctx.run, _process_job, job))
```

这里还有一个很实用的设计：Hermes 对 cron 不使用简单的“总时长超时”，而是使用 inactivity timeout。只要 Agent 还在持续调用工具、接收 stream、发起 API 请求，就可以运行很久；只有长时间没有活动，才认为卡死。

Agent 侧用 `_touch_activity()` 更新时间：

- `run_agent.py`

```python
self._last_activity_ts = time.time()
self._last_activity_desc = desc
```

外部通过 `get_activity_summary()` 查询：

```python
return {
    "seconds_since_activity": round(elapsed, 1),
    "current_tool": self._current_tool,
    "api_call_count": self._api_call_count,
}
```

这比固定 30 分钟杀掉任务更适合 Agent，因为 Agent 任务的耗时波动很大。

## 5. `multiprocessing.Pool`：批处理用多进程，而不是多线程

离线数据集批处理和 Gateway 聊天不一样。它更像跑大量独立样本，CPU、内存、网络调用都可能比较重。Hermes 的 `batch_runner.py` 使用 `multiprocessing.Pool`：

```python
with Pool(processes=self.num_workers) as pool:
    for result in pool.imap_unordered(_process_batch_worker, tasks):
        ...
```

多进程的好处是隔离更强：每个 worker 有自己的 Python 解释器、内存空间和 Agent 实例。它也绕开了 GIL 对 CPU-bound 任务的限制。

同时 batch runner 有 checkpoint：

```python
self._save_checkpoint(checkpoint_data, lock=checkpoint_lock)
```

所以中断后可以 resume。这是批处理系统里比“并发”更重要的能力：可恢复性。

## 6. `subprocess.Popen` + process registry：非阻塞管理外部进程

Agent 经常需要启动 dev server、测试、爬虫、训练脚本。如果直接前台执行，Agent 会一直等待。Hermes 提供 `terminal(background=true)`，底层通过 process registry 管理：

- `tools/process_registry.py`

它记录：

```text
id: proc_xxx
pid
command
started_at
output_buffer
exit_code
notify_on_complete
watch_patterns
```

启动后台进程时使用 `subprocess.Popen`：

```python
proc = subprocess.Popen(
    [user_shell, "-lic", f"set +m; {command}"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    stdin=subprocess.PIPE,
)
```

然后 Agent 可以用 `process` 工具查询：

- `process(action="poll")`
- `process(action="log")`
- `process(action="wait")`
- `process(action="kill")`
- `process(action="submit")`

这是一种很实用的异步通信模型：进程继续跑，Agent 通过 registry 轮询或等待结果。

## 7. `queue.Queue`：后台事件通知

后台进程完成、watch pattern 命中等事件不会直接打断当前执行流，而是进入队列：

- `tools/process_registry.py`

```python
self.completion_queue = queue.Queue()
```

事件会被格式化成类似：

```text
[IMPORTANT: Background process proc_xxx completed ...]
```

然后 CLI 或 Gateway 在合适的时机 drain queue，把它作为重要上下文交给 Agent 或通知用户。

这体现了异步通信中的常见思想：生产者和消费者解耦。进程 reader 线程只负责生产事件；Agent/Gateway 在自己的节奏里消费事件。

## 8. 锁：并发安全比并发本身更重要

Hermes 用了多种锁：

- `threading.Lock` 保护内存结构
- cron jobs 文件写入锁
- 跨进程文件锁防止多个 scheduler 同时 tick
- session guard 防止同会话并发 Agent

例如 cron tick 使用文件锁保证 at-most-once：

- `cron/scheduler.py`

```python
fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
```

Windows 下则用 `msvcrt.locking()`。

这点非常关键：异步系统最怕“看似能跑，偶发重复执行”。Hermes 通过先推进 `next_run_at`、再执行 due jobs 的方式，避免多个 gateway 实例重复跑同一个 cron job。

## 总结

Hermes Agent 的 Python 并发模型可以概括为：

```text
asyncio          负责 Gateway 事件调度
threading        承载同步 Agent、后台任务、stdout reader
executor         在 async 环境中运行 blocking code
multiprocessing  用于离线批处理并行
subprocess       管理外部长进程
queue            做后台事件通信
lock/file lock   做并发安全
activity tracker 做长任务健康检查
```

它没有追求“全 async”，而是根据任务性质选择合适工具：

- 网络平台接入：`asyncio`
- 同步 Agent loop：executor/thread
- CLI 后台任务：thread
- 外部命令：`Popen` + registry
- 定时任务：cron ticker + thread pool
- 离线批处理：multiprocessing
- 状态协调：queue + lock + checkpoint

这也是 Python 并发编程里最值得借鉴的一点：不要迷信单一模型。真实系统通常是混合并发，关键是边界清楚、状态可控、失败可恢复。
