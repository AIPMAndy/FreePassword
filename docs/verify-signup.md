# 怎么确认「开放注册」真的关掉了

这个坑值得单独写一篇，因为**大部分教程给的验证方法都是错的**，包括我一开始用的那套。

## 三个错误信号

### 错误信号 1：注册接口返回 404，就以为关掉了

```
POST /identity/accounts/register  ->  404
```

看起来像"路由被卸载了"，很安全。但真相是：**这个路径在 Vaultwarden 1.37.x 里本来就不存在**。

实测：把 `SIGNUPS_ALLOWED` 设成 `true`（明确开放注册）后，同一个路径依然返回 404。也就是说这个 404 与开关状态无关，拿它当证据只能得出错误结论。

1.37.x 的真实端点是：

```
POST /identity/accounts/register/finish
```

### 错误信号 2：`/api/config` 里 `disableUserRegistration: false`，就以为注册开着

```
GET /api/config
{"settings": {"disableUserRegistration": false}}
```

这个字段对应源码里的 `is_signup_disabled()`：

```rust
pub fn is_signup_disabled(&self) -> bool {
  (!self.signups_allowed()
   && self.signups_domains_whitelist().is_empty()
   && (self.mail_enabled() || !self.invitations_allowed()))
  || (self.sso_enabled() && self.sso_only())
}
```

注意 `(self.mail_enabled() || !self.invitations_allowed())`：没配 SMTP、又允许邀请时，这个条件为 `false`，整个表达式就是 `false`。

**这是有意的**：这种配置下管理员仍然能邀请人，界面不应该把注册入口彻底藏掉。所以它既不等于"注册开着"，也不等于"注册关了"——它只回答"要不要隐藏注册链接"。

### 错误信号 3：容器里 `env` 显示 `SIGNUPS_ALLOWED=false`，就以为生效了

环境变量确实改了，但它是配置的**输入**，不是结果。配置有没有被容器真正读到、判断有没有真的走到，还得看行为。

## 正确的验证方法

用注册流程的**第一步**，它是唯一直达 `is_signup_allowed(&email)` 判断的端点：

```bash
curl -s -X POST https://vault.example.com/identity/accounts/register/send-verification-email \
  -H 'Content-Type: application/json' \
  -d '{"email":"probe-do-not-use@example.com","name":"probe"}'
```

源码里这一步失败时的分支：

```rust
// src/api/identity.rs
if !CONFIG.is_signup_allowed(&email) {
    err!("Registration not allowed or user already exists")
}
```

期望结果：

```
{"message":"Registration not allowed or user already exists", ...}
```

这个端点用的 payload 结构简单（只有 email 和 name），不需要构造真实的加密密钥材料，所以可以干净地做 A/B 对照：

| 状态 | 同一请求的返回 |
|---|---|
| `SIGNUPS_ALLOWED=true` | 一个 `register_verify` 的 JWT（说明放行） |
| `SIGNUPS_ALLOWED=false` | `Registration not allowed or user already exists` |

**两次用同一个邮箱、同一个 payload，唯一变量是开关状态。** 这才叫验证。

## 为什么不用 `/register/finish` 验证

它是注册的最后一步，需要完整的 `emailVerificationToken` 链路，请求体里还有 `masterPasswordAuthentication`、`masterPasswordUnlock` 这类必须带真实密钥材料的嵌套结构。用假数据只会在 Rocket 的数据解析守卫那里就失败，返回：

```
422 Unprocessable Entity（data did not match any variant of untagged enum RegisterDataCompat）
400 Bad Request（Registration is missing required parameters）
```

**根本走不到 `is_signup_allowed` 那一行**，所以它无法用来验证注册开关，只能用来验证"我构造的 payload 对不对"。

## 顺带一条：改完必须重建容器

```bash
docker compose up -d --force-recreate
```

`restart` 不会重新读取环境变量。而且要注意——如果只改了 `.env` 而没加 `--force-recreate`，你会在 `docker ps` 里看到容器"正常重启"，环境变量却是旧的。**验证之前先确认 `docker exec` 里的值是新的。**

## 一句话总结

判断注册是否关闭，只认一个证据：

```
POST /identity/accounts/register/send-verification-email
  → "Registration not allowed or user already exists"
```

其它信号（404、`disableUserRegistration`、环境变量）都不能单独作为依据。
