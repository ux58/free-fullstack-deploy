# 预签名直传：Serverless 大文件上传的完整实现模式

适用场景：Vercel/Netlify 等 Serverless 平台（函数请求体上限 4.5MB）需要上传
音频/视频/大图片。核心思想：**服务端只签发 URL，文件不经过应用服务器**，
落库前服务端复核对象真实属性。

以下代码来自真实项目（TypeScript + AWS SDK v3 + Drizzle），可直接适配。

## 1. 存储适配器扩展（可选能力，不破坏本地存储）

```typescript
// src/server/storage/types.ts
export interface StorageAdapter {
  readonly driver: "local" | "s3";
  put(key: string, data: Uint8Array, mime: string): Promise<void>;
  get(key: string, range?: StorageRange): Promise<StoredObject | null>;
  delete(key: string): Promise<void>;
  test(): Promise<void>;
  /** 签发客户端直传 PUT URL；不支持的适配器为 undefined */
  presignPut?(path: string, mime: string, expiresInSec: number): Promise<string>;
  /** 直传后服务端复核用；不支持的适配器为 undefined */
  head?(path: string): Promise<{ size: number; contentType: string } | null>;
}
```

S3 适配器实现（Supabase/R2/MinIO 通用，注意 `forcePathStyle`）：

```typescript
// src/server/storage/s3.ts（节选）
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { PutObjectCommand, HeadObjectCommand, S3Client } from "@aws-sdk/client-s3";

constructor(private readonly cfg: S3Config) {
  this.client = new S3Client({
    region: cfg.region || "us-east-1",
    endpoint: cfg.endpoint || undefined,
    forcePathStyle: Boolean(cfg.endpoint), // Supabase/R2/MinIO 必须 path-style
    credentials: { accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey },
  });
}

async presignPut(path: string, mime: string, expiresInSec: number): Promise<string> {
  const cmd = new PutObjectCommand({ Bucket: this.cfg.bucket, Key: path, ContentType: mime });
  return getSignedUrl(this.client, cmd, { expiresIn: expiresInSec });
}

async head(path: string) {
  try {
    const res = await this.client.send(new HeadObjectCommand({ Bucket: this.cfg.bucket, Key: path }));
    return { size: Number(res.ContentLength ?? 0), contentType: res.ContentType ?? "" };
  } catch { return null; }
}
```

依赖：`npm i @aws-sdk/client-s3 @aws-sdk/s3-request-presigner`

## 2. 签发端点（上传前校验，缩小攻击面）

```typescript
// src/app/api/v1/upload-url/route.ts
export async function POST(req: NextRequest) {
  await requireScope(req, "items:write");
  const body = uploadUrlSchema.parse(await req.json()); // { kind, mime, filename, size }
  // 1) MIME 白名单（不信任扩展名与客户端声明的最终属性，这里只是提前拒绝）
  const whitelist = body.kind === "audio" ? AUDIO_MIMES : IMAGE_MIMES;
  if (!whitelist.includes(body.mime)) throw new ApiError(415, "unsupported_media_type", "格式不受支持");
  // 2) 大小声明预检（真实复核在落库前）
  if (body.size > limit) throw new ApiError(413, "payload_too_large", "超过大小限制");
  // 3) 仅 S3 后端支持
  const storage = await getStorage();
  if (!storage.presignPut) throw new ApiError(400, "validation_error", "当前存储后端不支持直传");
  // 4) 服务端生成随机键（绝不由客户端指定路径）
  const path = `${body.kind === "audio" ? "audio" : "cover"}/${randomBytes(12).toString("hex")}.${MIME_EXT[body.mime]}`;
  const url = await storage.presignPut(path, body.mime, 600);
  return NextResponse.json({ url, key: composeKey(storage.driver, path), mime: body.mime, expiresIn: 600 });
}
```

## 3. 落库复核（安全关键：不信任客户端）

客户端提交 JSON：`{ ...metadata, audioUpload: { key: "s3:audio/xxx.mp3", name: "原文件名.mp3" } }`。
服务端用 `head()` 拿对象**真实**大小与类型，客户端声明只提供展示名：

```typescript
async function resolveUploadedRef(ref: UploadedRef, kind: "audio" | "image", limit: number): Promise<StoredMeta> {
  const parsed = parseStoredKey(ref.refKey); // 键格式校验：^(local|s3):[A-Za-z0-9][A-Za-z0-9._/-]*$
  const allowedPrefix = kind === "audio" ? "audio/" : "cover/";
  // 只接受本服务生成的目录前缀 + 当前驱动，拒绝路径穿越
  if (!parsed || parsed.driver !== "s3" || !parsed.path.startsWith(allowedPrefix) || parsed.path.includes("..")) {
    throw new ApiError(422, "validation_error", "上传键非法");
  }
  const adapter = await getStorageForKey(ref.refKey);
  if (!adapter?.head) throw new ApiError(422, "validation_error", "当前存储后端不支持直传对象");
  const meta = await adapter.head(parsed.path);
  const whitelist = kind === "audio" ? AUDIO_MIMES : IMAGE_MIMES;
  if (!meta || meta.size === 0 || meta.size > limit || !whitelist.includes(meta.contentType as never)) {
    throw new ApiError(415, "validation_error", "直传对象校验失败（不存在/超限/类型不符）");
  }
  return { key: ref.refKey, name: ref.name, mime: meta.contentType, size: meta.size };
}
```

## 4. 前端分流（storage-mode 自动选择通道）

```typescript
// 前端挂载时探测
const { directUpload } = await apiJson<{ driver: string; directUpload: boolean }>("/api/v1/storage-mode");

// 提交时
if (directUpload && (audio || cover)) {
  const signed = await apiJsonBody("POST", "/api/v1/upload-url",
    { kind: "audio", mime: guessMime(file), filename: file.name, size: file.size });
  const res = await fetch(signed.url, { method: "PUT", body: file, headers: { "Content-Type": signed.mime } });
  if (!res.ok) throw new Error("直传失败 " + res.status);
  // 然后提交 JSON：{ ...payload, audioUpload: { key: signed.key, name: file.name } }
} else {
  // Node 常驻/本地存储：传统 multipart
  await apiUpload("POST", "/api/v1/items", payload, { audio, cover });
}
```

MIME 兜底推断（`file.type` 可能为空）：

```typescript
function guessMime(file: File): string {
  if (file.type) return file.type;
  const ext = file.name.split(".").pop()?.toLowerCase();
  return ({ mp3: "audio/mpeg", ogg: "audio/ogg", wav: "audio/wav", flac: "audio/flac",
            m4a: "audio/mp4", jpg: "image/jpeg", png: "image/png", webp: "image/webp",
            gif: "image/gif", avif: "image/avif" })[ext] ?? "application/octet-stream";
}
```

## 5. Serverless 下无法解析 ID3 的补偿

直传后服务端没有文件 buffer，`music-metadata` 解析不可用（拉回 100MB 不现实）。补偿：

- **时长**：浏览器端 `const probe = new Audio(); probe.src = URL.createObjectURL(file);
  probe.onloadedmetadata = () => duration = Math.round(probe.duration)`（免费、即时）
- **标签**（艺术家/专辑/封面）：接受用户手填，或引入 `music-metadata` 的浏览器构建
  （体积较大，按需取舍）

## 6. CORS 与私有性

- Supabase S3 网关默认 CORS `*`（实测响应头 `access-control-allow-origin: *`）——
  预签名 PUT 本身就是授权凭证，无需开放桶
- 桶保持**私有**；下载走应用服务端流式代理（`/files/:key` → GetObject + Range 转发），
  既能做访问控制又能支持音频拖动播放（206）
- 若追求极致播放性能，可改预签名 GET 直连对象存储，但会失去服务端访问控制

## 7. 验证脚本

见 [scripts/verify-deploy.sh](../scripts/verify-deploy.sh)：对线上环境完整走一遍
签发 → 直传 → 落库复核 → Range 流式 → 删除，并断言每步状态码与响应头。
