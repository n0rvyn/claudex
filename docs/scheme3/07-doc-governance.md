# 方案三文档治理

Date: 2026-04-20

## 1. 目的

本文件规定本目录的写作和升级规则。

目标只有两个：

- 避免把猜测写进正式文档
- 避免后续文档重新混回方案一或其他路线

## 2. 文档类型

本目录只允许出现四类内容：

### 2.1 项目定义

放在：

- [00-project-brief.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/00-project-brief.md)

内容：

- 用户硬约束
- 范围边界
- 当前项目目标

### 2.2 已验证事实

放在：

- [01-validated-baseline.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/01-validated-baseline.md)
- [03-anthropic-edge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/03-anthropic-edge.md)
- [04-upstream-edge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/04-upstream-edge.md)

内容：

- 只写已验证边界
- 每条事实都要能追到证据

### 2.3 设计决策

放在：

- [02-target-architecture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/02-target-architecture.md)

内容：

- 基于已验证事实做出的设计选择
- 不写未经样本验证的协议细节

### 2.4 待验证内容

放在：

- [05-validation-matrix.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/05-validation-matrix.md)
- [06-open-questions.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/06-open-questions.md)

内容：

- 未决问题
- 验证方法
- 通过标准

## 3. 更新顺序

拿到新证据后，必须按这个顺序更新：

1. 先更新研究稿或新增证据稿
2. 再更新 `01-validated-baseline.md`
3. 若证据影响项目目标，更新 `00-project-brief.md`
4. 若证据影响设计边界，更新 `02-target-architecture.md`
5. 最后删改 `05-validation-matrix.md` 与 `06-open-questions.md`

## 4. 允许写入的证据来源

允许来源：

- 官方文档
- 官方开源代码
- 本机 CLI 输出
- 本机运行态探针

不允许来源：

- 训练记忆
- 没抓到样本时的字段猜测
- “按经验推断上游应该这样”

## 5. 升级规则

一个结论从“问题”升级到“事实”，必须满足：

1. 至少两类证据支持
2. 其中至少一类来自运行态或源码
3. 文档中能明确指出证据落点

## 6. 禁止写法

- 把“当前没抓到样本”写成“不存在”
- 把“运行时看到一次”写成“协议稳定保证”
- 把 `/wham/tasks` 写成方案三主面
- 把 `app-server` 写成方案三主面
- 把 `/responses` 的未知字段补成确定值

## 7. 术语固定

本目录统一使用以下术语：

- `Claude 入口面`
  指 Claude Code 看到的 Anthropic-compatible 面
- `主推理面`
  指方案三上游 `/responses`
- `辅助产品面`
  指 `/backend-api/...`
- `方案一`
  指 `Anthropic Messages <-> codex app-server` 语义桥
- `方案三`
  指 `Anthropic-compatible gateway -> /responses`

## 8. 删除规则

当某个问题被验证完成时：

- 如果得到确定结论，迁移到 `01-validated-baseline.md`
- 如果推翻当前设计，先更新 `00-project-brief.md` 与 `02-target-architecture.md`
- 不允许把“已解决问题”继续留在 `06-open-questions.md`
