<!-- tpl:v2 -->
# staging 校验模板（注入主模型，每轮组装前过一遍）

## 来源追溯（硬）
src 的 MSG id → 对照 raw.log 对应块原文：
- 约束正文能在用户原话中找到依据 → 过
- 找不到依据 = 子代理自己推断的 → Reject（幻觉约束，强制注入会污染所有后续任务包）
- REBUILT- 来源 = Verify 重建条目，核对原 MSG 后放行

## 决策与状态（软）
- 新决策与工作集决策日志矛盾 → 找用户裁决，不自作主张
- 待办/未决问题更新与事实一致才 Approve

## 同轮操作顺序（钉死，防版本与冲突错位）
1. 逐条 Approve / Reject
2. **先 Supersede**（约束库操作，不动工作集 ver）——Approve 的约束若覆盖旧约束，
   同轮重组前完成，让 pending-recheck 先生成
3. **后 SaveState**（工作集操作，必须重读工作集拿新 ver 再写，禁止凭旧版本直写）
   顺序颠倒会冲突：SaveState 改了 ver，后续引用全对不上。

通过 → ApproveStaging；拒绝 → RejectStaging（进 rejected/ 留痕）。
子代理回写首行带 TASK-SWITCH 时，Approve 会自动落邻域召回信号，无需手工处理。
