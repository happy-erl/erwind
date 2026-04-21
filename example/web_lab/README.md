# Erwind HTTP API 演示网站

这是一个用于演示和测试 Erwind HTTP API 功能的交互式网页。

## 功能概览

这个演示网站提供了对所有 Erwind HTTP API 端点的可视化调用界面：

### 1. 健康检查
- **GET /ping** - 检查服务器是否存活
- **GET /info** - 获取服务器节点信息
- **GET /stats** - 获取统计信息（Topic/Channel 状态）

### 2. Topic 管理
- **POST /topic/create?topic=** - 创建新的 Topic
- **POST /topic/delete?topic=** - 删除指定的 Topic
- **POST /topic/pause?topic=** - 暂停 Topic（停止接收消息）
- **POST /topic/unpause?topic=** - 恢复 Topic
- **GET /topic/list** - 列出所有 Topics

### 3. Channel 管理
- **POST /channel/create?topic=&channel=** - 在指定 Topic 下创建 Channel
- **POST /channel/delete?topic=&channel=** - 删除指定的 Channel

### 4. 消息发布
- **POST /pub?topic=** - 向指定 Topic 发布单条消息
- **POST /mpub?topic=** - 批量发布消息（每行一条）
- **POST /dpub?topic=&defer=** - 延迟发布消息（指定延迟毫秒数）

## 使用方法

### 1. 启动 Erwind 服务器

首先确保 Erwind HTTP API 服务已启动：

```bash
# 在项目根目录
cd /home/tang/erl/erwind
rebar3 shell

# 或者在 Erlang shell 中手动启动
application:ensure_all_started(erwind).
```

默认情况下，HTTP API 服务会在端口 `4151` 启动。

### 2. 打开演示网站

直接用浏览器打开 `index.html` 文件：

```bash
# 方式1：直接打开文件
open example/web_lab/index.html

# 方式2：使用 Python 简易 HTTP 服务器
cd example/web_lab
python3 -m http.server 8080
# 然后访问 http://localhost:8080
```

### 3. 配置 API 服务器地址

在页面顶部的"API 服务器配置"区域：
- 默认地址：`http://127.0.0.1:4151`
- 如果你的 Erwind 服务运行在其他地址或端口，请修改
- 点击"检查连接"按钮验证连接状态

### 4. 使用演示功能

#### 创建 Topic 和 Channel
1. 在"Topic 管理"卡片中，输入 Topic 名称，点击"创建"
2. 在"Channel 管理"卡片中，输入 Topic 名称和 Channel 名称，点击"创建"

#### 发布消息
1. 在"消息发布"卡片的 "/pub" 部分
2. 输入 Topic 名称和消息内容
3. 点击"发布"按钮

#### 查看实时状态
页面底部的"Topic & Channel 实时状态"区域会自动：
- 显示所有 Topics 及其统计信息
- 显示每个 Topic 下的 Channels
- 标注暂停状态的 Topic/Channel
- 每 5 秒自动刷新数据

#### 批量操作
- **批量发布**：在 "/mpub" 中输入多行消息，每行作为一条独立消息
- **延迟发布**：在 "/dpub" 中设置延迟时间（毫秒）

## 动画效果

网站包含以下动画效果：

1. **连接状态指示器** - 显示与 API 服务器的连接状态（在线/离线）
2. **卡片悬停效果** - 鼠标悬停时卡片上浮
3. **API 项目滑动效果** - 悬停时向左滑动
4. **Topic 项目淡入动画** - 数据加载时的渐入效果
5. **刷新按钮旋转** - 点击刷新时的旋转动画
6. **结果面板展开** - API 响应结果的滑入显示

## 数据流向

```
浏览器 (index.html)
    ↕  HTTP 请求 (Fetch API)
Erwind HTTP API (端口 4151)
    ↕  内部调用
Topic/Channel 进程
```

## 注意事项

1. **跨域问题**：默认启用 CORS，允许所有来源访问。如需禁用或自定义，修改配置：

   ```erlang
   %% 在 app.config 或启动时设置
   %% 禁用 CORS
   application:set_env(erwind, cors, disabled).

   %% 或自定义允许的来源
   application:set_env(erwind, cors, #{enabled => true, origin => <<"https://example.com">>}).
   ```

2. **实时更新**：可视化区域每 5 秒自动刷新，也可以点击右下角的刷新按钮手动更新。

3. **错误处理**：所有 API 调用都会显示详细的响应状态和数据，包括错误信息。

## 文件结构

```
example/web_lab/
├── index.html      # 演示网站主页面
└── README.md       # 本说明文件
```

## 扩展开发

你可以基于这个演示网站进行扩展：

1. **添加 WebSocket 支持** - 实时推送消息到页面
2. **历史记录** - 记录所有 API 调用和响应
3. **性能图表** - 使用 Chart.js 展示 Topic 消息速率
4. **消息追踪** - 追踪单条消息的流转过程
5. **消费者模拟** - 模拟消费者订阅和接收消息

## 相关文件

- HTTP API 实现：[src/http/erwind_http_api.erl](../../src/http/erwind_http_api.erl)
- HTTP 监督者：[src/http/erwind_http_sup.erl](../../src/http/erwind_http_sup.erl)
- API 测试：[test/erwind_http_api_tests.erl](../../test/erwind_http_api_tests.erl)
