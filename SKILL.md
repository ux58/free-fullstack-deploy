---
name: free-fullstack-deploy
description: Deploy a full-stack Node/Next.js app to 100% free tiers with zero credit card, using Render + Neon Postgres + Supabase Storage (S3-compatible). Use whenever the user wants to 部署/上线/发布 a full-stack or Node web app for free, mentions 免费服务器/free hosting/free tier, presigned upload/直传, or hits Vercel/R2/Supabase/Render signup blocks or build failures — even if they don't say "free" explicitly.
---

# Free Full-Stack Deploy（免费全栈部署）

将 Node/Next.js 全栈应用部署到完全免费的平台组合，**全程无需信用卡**。
本 skill 来自一次真实部署（Next.js 音乐管理器 → Render + Neon + Supabase，全部免费额度，
端到端验证通过），包含实操步骤、平台风控绕行和免费层陷阱。

## 0. 先做平台选型（读这个再动手）

| 需求 | 推荐 | 避坑 |
|---|---|---|
| Node 常驻 + 数据库 + 对象存储，全免费 | **Render + Neon + Supabase** | 见下 |
| Serverless（自动扩缩） | Vercel + Neon + Supabase | Vercel 对新账号有风控 |
| 有信用卡 / 已有账号 | Vercel / R2 均可 | R2 激活必须绑卡 |

**风控与绑卡现实（2025-26 实测）**：
- **Vercel**：新 GitHub 账号 + 代理 IP 注册会被 `user_blocked`（"requires further verification"），
  恢复要走人工表单，等不起 → 直接换 Render。
- **Cloudflare R2**：激活订阅**强制绑卡**（免费额度内不扣费但必须验证支付方式）→ 无卡用户换 Supabase。
- **Render / Neon / Supabase**：GitHub OAuth 登录，零绑卡。

详细对比与每个平台的坑（休眠/暂停策略、OAuth 按钮禁用绕行、hCaptcha）：
读 [references/platform-notes.md](references/platform-notes.md)。

## 1. 架构前提：应用必须无状态化

免费托管没有持久磁盘。部署前确认应用满足：

- **数据库外置**：SQLite 本地文件不可用（Render 重建即丢）。若应用支持多数据库驱动，
  切到 Postgres（Neon）。纯 SQLite 应用需要改造成 Postgres 或接受数据丢失。
- **文件存储外置**：上传文件不能落本地磁盘。若应用有存储抽象层，接 S3 兼容协议
  （Supabase Storage 支持 S3 协议；MinIO/R2/OSS 同理）。
- **会话/限流内存实现**：单实例可接受；Render 免费层就是单实例。

## 2. Serverless 才需要：预签名直传（4.5MB 请求体上限）

Vercel/Netlify 等 Serverless 函数有请求体上限（Vercel Hobby 4.5MB）。
大文件上传（音频/视频）必须改为**两段式直传**：

1. `POST /api/upload-url`：校验 MIME 白名单与大小声明 → 生成随机对象键 → 签发
   10 分钟有效的 S3 Presigned PUT URL
2. 浏览器 `fetch(url, { method: "PUT", body: file, headers: { "Content-Type": mime } })` 直传对象存储
3. `POST /api/items`（JSON）：提交元数据 + 对象键；**服务端必须 `HeadObject` 复核**
   对象真实大小与 Content-Type——绝不信任客户端声明的大小

Node 常驻平台（Render）无此限制，multipart 直传应用即可，两套通道用
`GET /api/storage-mode` 让前端自动分流。

完整实现模式（存储适配器接口、路由、前端分流、安全复核）：
读 [references/presigned-upload.md](references/presigned-upload.md)。

## 3. 部署步骤（Render + Neon + Supabase）

顺序执行，每步都有明确的产出物：

### 3.1 Neon（数据库，~5 分钟）
1. <https://neon.tech> → GitHub 登录 → Create project（区域选 Singapore）
2. 复制 Connection string（形如 `postgresql://user:pass@ep-xxx-pooler.region.aws.neon.tech/db?sslmode=require`）
3. 本机建表：`DATABASE_DRIVER=postgres DATABASE_URL="<串>" npx drizzle-kit push`
   （非 Drizzle 项目用 Prisma migrate / TypeORM sync / 手写 SQL）
4. 产出：连接串（后面配到 Render 环境变量）

### 3.2 Supabase（对象存储，~10 分钟）
1. <https://supabase.com> → GitHub 登录 → 创建组织（Free）→ 创建项目（Asia-Pacific 区域）
2. Storage → **New bucket** → 私有桶（Public 关闭），名字如 `app-files`
3. Storage → **Settings → S3** → 确认 S3 protocol 开关打开 → 记下 **Endpoint**
   （`https://<ref>.storage.supabase.co/storage/v1/s3`）与 **Region**（如 `ap-south-1`）
4. 同页 **New access key** → 命名 → **立即复制** Access Key ID / Secret（Secret 只显示一次）
5. CORS：Supabase S3 网关默认 `access-control-allow-origin: *`，无需额外配置（实测）
6. 产出：endpoint / region / bucket / accessKeyId / secret 五元组

### 3.3 Render（应用托管，~15 分钟）
1. <https://dashboard.render.com> → GitHub 登录 → 授权并安装 GitHub App
   （选 **Only select repositories** 只授权目标仓库，最小权限）
2. New → Web Service → 选仓库。若检测到 Next.js 会自动填充：
   - Build: `npm install; npm run build`　Start: `npm run start`
3. **Region: Singapore**（离国内最近）；**Instance: Free**（0.1 CPU / 512MB）
4. Environment Variables：
   - `DATABASE_DRIVER=postgres`（按你的应用约定）
   - `DATABASE_URL=<Neon 连接串>`
   - `JWT_SECRET=<openssl rand -base64 48 生成>`
5. Deploy。免费实例构建约 3-8 分钟

### 3.4 首次初始化
- 应用有初始化向导（如 /setup）→ 直接访问；没有 → 用 seed 脚本建管理员
- 存储后端切换类配置若存数据库，可直接向 Neon 的 settings 表 INSERT 预置，
  部署完即生效（跳过 UI 手填）

## 4. 端到端验证（必须做完才算部署成功）

运行本 skill 自带脚本（health → 初始化 → 登录 → 存储模式 → 直传 → 服务端复核 → Range 流式 → 删除）：

```bash
BASE_URL=https://your-app.onrender.com SETUP_USER=admin SETUP_PASS='xx' \
  bash scripts/verify-deploy.sh
```

脚本自动生成带合法魔数的测试文件、验证 `Content-Range` 分段、最后清理测试数据。
核心断言（脚本失败时人工核对）：
- `GET /api/health` → 200
- 初始化端点 → 201
- 存储模式接口 → `"directUpload": true`（配置已生效的标志）
- 直传 PUT → 200，且 **CORS 头存在**
- 创建接口 → 201，且返回的文件大小 = 对象实际大小（证明服务端复核生效）
- `Range: bytes=0-15` 请求文件 → **206** + 正确 `Content-Range`（流式播放的关键）
- 删除 → 204

## 5. 部署失败排查（按命中率排序）

1. **构建期 TS 报错**：CI 会 typecheck 测试文件（vitest 不查但 `next build` / tsc 查）。
   本地跑一次 `npx tsc --noEmit` 再推送。曾踩坑：测试文件用到的 schema 忘了 import。
2. **Vercel `user_blocked`**：换 Render，不要纠缠人工审核。
3. **推送超时/ECONNRESET**：国内网络对 GitHub 直连阻断。让用户开代理软件并开"系统代理"，
   读取注册表 `ProxyEnable/ProxyServer` 拿到端口后 `git config http.proxy http://127.0.0.1:<port>`；
   大仓库再加 `git config http.version HTTP/1.1 && git config http.postBuffer 524288000`。
4. **Node 脚本请求对象存储被重置**：Node 的 fetch/AWS SDK 不走系统代理。
   Node 24+ 用 `NODE_USE_ENV_PROXY=1 HTTPS_PROXY=http://127.0.0.1:<port>`；
   AWS SDK 本身不吃这个变量，改用"本地签名 + 代理 fetch"的方式验证（见 verify-deploy.sh）。
5. **内存不足 OOM**（512MB 构建）：`NODE_OPTIONS=--max-old-space-size=460`，或构建命令换 webpack。

## 6. 免费层长期运行的已知边界（务必告知用户）

- **Render Free**：闲置 15 分钟休眠，唤醒 ~50 秒（用户感知"第一次打开很慢"）。$7/月常驻。
- **Supabase Free**：项目 7 天无 API 活动会暂停（控制台一键恢复）；正常使用不触发。
- **Neon Free**：空闲挂起，首次请求 ~1s 冷启动；连接串密码泄露时在控制台 Reset password。
- 免费额度都按月滚动，个人音乐库/工具站规模完全够用。

## 7. 部署后安全清单

- [ ] 数据库连接串 / JWT 密钥若曾在聊天/日志中暴露 → 控制台轮换（Neon Reset password、换 JWT_SECRET）
- [ ] 管理员默认密码改为用户自己的
- [ ] S3 CORS 的 `AllowedOrigins` 从 `*` 收紧到实际域名
- [ ] 对象键校验：只接受本服务生成的路径前缀 + 驱动前缀，拒绝 `..`（见 references/presigned-upload.md）
