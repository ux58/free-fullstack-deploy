# free-fullstack-deploy

把全栈 Node/Next.js 应用部署到 **100% 免费平台**（Render + Neon Postgres + Supabase Storage）的
实战 Skill，**全程零信用卡**。提取自一次真实部署的完整历程：平台风控绕行、Serverless 4.5MB
上传限制的预签名直传改造、免费层休眠/暂停策略、构建失败排查、端到端验证脚本。

线上成果：一个 Next.js 全栈音乐管理器运行在 `*.onrender.com`，大文件直传对象存储，
Range 流式播放，全部免费额度。

## 这是什么

一个通用 Agent Skill（`SKILL.md` + 参考文档 + 验证脚本），
安装后编码代理会在你提到"免费部署 / 上线 / 免费服务器 / 服务器托管 / Serverless 上传限制"等
场景时自动加载这套方法论。

## 目录结构

```
free-fullstack-deploy/
├── SKILL.md                        # 主工作流：选型 → 无状态化 → 直传模式 → 部署步骤 → 验证 → 排查
├── references/
│   ├── platform-notes.md           # 各平台实测坑：Vercel 风控、R2 绑卡、Render/Neon/Supabase 免费层行为、国内网络代理
│   └── presigned-upload.md         # 预签名直传完整实现（存储适配器 / 签发端点 / 服务端复核 / 前端分流）
└── scripts/
    └── verify-deploy.sh            # 部署后端到端验证（health→setup→登录→直传→Range 流式→清理）
```

## 安装

### 用户级安装（所有项目可用）

```bash
git clone https://github.com/ux58/free-fullstack-deploy.git ~/.agents/skills/free-fullstack-deploy
```

或手动复制到任意 Agent Skills 发现路径（如 `~/.agents/skills/`、项目内 `.agents/skills/`）。

### 其他支持 SKILL.md 约定的 Agent

复制 `SKILL.md` 与 `references/`、`scripts/` 到对应技能目录即可——
格式遵循开放的 Agent Skills 约定，各主流编码代理均可识别。

## 快速上手（不装 skill 也能照做）

1. **选型**：无卡用户直接用 Render + Neon + Supabase（Vercel 会风控新账号，R2 要绑卡）
2. **无状态化**：数据库切 Postgres、文件走 S3 协议对象存储
3. **建库**：Neon 建项目 → `DATABASE_URL=<串> npx drizzle-kit push`
4. **建桶**：Supabase 私有桶 + S3 访问密钥（endpoint/region/key 五元组）
5. **部署**：Render Web Service（Singapore / Free）+ 三个环境变量
6. **验证**：`BASE_URL=https://xxx.onrender.com SETUP_USER=... SETUP_PASS=... bash scripts/verify-deploy.sh`

## 来源与可靠性声明

- 全部步骤在 2026-10 的一次真实部署中逐步执行并验证，非理论整理
- 平台策略（风控、免费额度、休眠阈值）随时间变化，`references/platform-notes.md` 中标注了实测时间
- 使用前建议花两分钟核对目标平台的当前政策

## License

MIT
