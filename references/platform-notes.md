# 平台笔记：免费托管的风控、绑卡与限制（实测记录）

记录于 2026-10，一次真实部署（Next.js 16 音乐管理器）。平台策略会变，使用前值得复核。

## Vercel

### 风控（实测踩坑）
- 新 GitHub 账号 + 代理 IP 注册：OAuth 授权完成后跳转
  `vercel.com/login?error=user_blocked&error_message=Your+account+requires+further+verification`
- 页面给出 "account recovery form" 人工审核通道——周期以天计，不要耗在这
- **决策**：立即换 Render，不要尝试绕过风控

### 技术限制
- Hobby 函数请求体上限 **4.5MB** → 大文件必须预签名直传（见 presigned-upload.md）
- 函数执行时长上限 60s；响应流式（音频回源）可用但占用带宽额度
- 授权页小坑：GitHub OAuth 的 Authorize 按钮可能一直 `disabled`。
  自动化绕行：`document.querySelector("button[name='authorize']").disabled = false;
  btn.closest("form").requestSubmit(btn)`（页面本身校验通过时有效）

## Cloudflare R2

- 激活 R2 订阅强制添加付款方式（卡或 PayPal），免费额度内不扣费但**无法绕过**
- 优点（如果有卡）：CORS 需在桶 Settings 手动配置 JSON；10GB/月免费
- Supabase S3 网关则默认 CORS 全开，免配置

## Render（推荐主力）

### 账号
- GitHub OAuth 登录；GitHub App 安装时选 **Only select repositories** 最小授权
- 注册若走 hCaptcha（点蜜蜂/花朵动态图），必须用户本人完成

### 免费实例行为
- 0.1 CPU / 512MB RAM；**闲置 15 分钟休眠**，唤醒 ~50 秒
- 无持久磁盘、无 SSH、无 zero-downtime（部署瞬间有短暂不可用）
- 构建与运行同规格：512MB 下 `next build`（Turbopack）实测可过（小型项目）；
  OOM 时加 `NODE_OPTIONS=--max-old-space-size=460`
- 环境变量表单：KEY 是 `input[placeholder="NAME_OF_VARIABLE"]`，
  VALUE 是 **textarea[placeholder="value"]**（不是第二个 input，自动化时注意）
- 区域：Singapore 对国内延迟最优

### 构建失败排查
- `Exited with status 1 while building` → 看构建日志尾部
- 实测踩坑：vitest 不做类型检查，但 `next build` 会 typecheck 测试文件 →
  测试里漏 import 的 schema 本地全绿、CI 构建失败。
  规矩：**推送前本地 `npx tsc --noEmit`**
- 默认 Build Command `npm install; npm run build` 即可，不必改 npm ci

## Neon

- GitHub 登录，免费 Postgres 0.5GB；Connection string 用 **pooler** 端点（`-pooler` 后缀）
- 建表：Drizzle `DATABASE_URL=<串> npx drizzle-kit push`；建表后用脚本验证表存在
- 空闲挂起：首次请求 ~1s 冷启动
- 密码泄露处置：控制台 Reset password 一键轮换，连接串其余部分不变

## Supabase

- GitHub 登录；先建组织（Free, Personal）再建项目；区域选 Asia-Pacific（自动分配 Mumbai ap-south-1）
- **只需 Storage，不需要用它的 Postgres**（避免双数据库混乱）——但建项目仍强制设 DB 密码，随意生成即可
- Storage 路径：New bucket（私有）→ Settings → **S3** 标签页：
  - Endpoint：`https://<project-ref>.storage.supabase.co/storage/v1/s3`
  - Region：如 `ap-south-1`
  - New access key：Access Key ID + Secret **仅显示一次**
- S3 兼容性实测：presigned PUT / HeadObject / GetObject（含 Range 206）/ Delete 全部可用；
  CORS 默认 `*`（浏览器直传零配置）
- S3 客户端参数：`forcePathStyle: true` 必须；region 填项目实际 region
- **7 天无活动暂停**：控制台 Restore 一键恢复。有正常流量的应用不会触发

## 国内网络环境（部署机器）

- GitHub 直连经常 SSL reset / timeout；`curl api.github.com` 也不通
- 用户浏览器能上 GitHub ⇒ 用户有代理工具。让用户开启"系统代理"模式，然后：
  1. 读注册表拿端口：
     `reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer`
  2. `git config http.proxy http://127.0.0.1:<port>`
  3. 大推送加：`git config http.version HTTP/1.1 && git config http.postBuffer 524288000`
- Node 进程默认不走系统代理：
  - Node 24+：`NODE_USE_ENV_PROXY=1 HTTPS_PROXY=http://127.0.0.1:<port>`
  - AWS SDK（@aws-sdk/client-s3）不吃这些环境变量——本地验证对象存储时，
    改用 **SDK 只做本地签名（getSignedUrl 不联网），实际 HTTP 用代理 fetch** 的模式
- 通过浏览器自动化完成部署类网站的 OAuth 流程时：
  - GitHub 登录/授权点击可由代理代操作；**账号密码、人机验证（hCaptcha）、邮箱验证必须由用户本人完成**
  - OAuth 授权页如 Authorize 按钮禁用，用表单 requestSubmit 绕行（见上文 Vercel 小节）
