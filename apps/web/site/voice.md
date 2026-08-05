---
name: TODO-your-voice
description: TODO 一句话概括这个站的语气。
locale: zh-CN
signals:
  # Machine-readable half — `pnpm analyze` reads exactly this block.
  # `avoid`: hits cost points. `expect`: zero hits across a group costs points.
  avoid:
    - weight: 8
      why: 学习目标脚手架——读者跳过它不会损失任何信息
      phrases: ['本文目标', '学完本文', '你将能够', '通过本文', '阅读本文后']
    - weight: 8
      why: 系列导航应该由 frontmatter 渲染，不该手写进正文
      phrases: ['系列导航', '上一篇:', '上一篇：', '下一篇:', '下一篇：']
    - weight: 8
      why: 收尾套话
      phrases:
        ['关键要点回顾', '要点回顾', '下一步学习', '总结与展望', '思考题', '练习题',
         '相关文章', '延伸阅读', '小结一下', '综上所述']
    - weight: 8
      why: 过渡填充词
      phrases: ['让我们一起', '让我们来', '接下来我们将', '在本节中', '值得注意的是', '核心概念解析']
    - weight: 8
      why: 标题党
      phrases: ['魔法', '黑魔法', '一探究竟', '揭秘', '全面解析', '终极指南']
    # `combo` only fires when several parts co-occur: 「第一层」单独出现是正常
    # 技术表达，三层并列才是递进模板。要求共现，才不会误伤正确的写作。
    - weight: 8
      why: 递进分层模板
      combo: ['第一层', '第二层', '第三层']
      min: 2
    - weight: 8
      why: 三段式套路
      combo: ['首先，', '其次，', '最后，']
      min: 3
    - weight: 8
      why: 优缺点对仗清单
      combo: ['优点：', '缺点：']
      min: 2
    - weight: 5
      cap: 15
      why: 未经验证却说成事实
      phrases: ['生产级', '完整实现', '最佳实践', '业界标准', '一定要', '必须使用']
  expect:
    - weight: 15
      why: 第一手经验——生成式文字最稳定缺的东西
      phrases:
        ['我自己', '我的经验', '我的判断', '我遇到', '我踩', '我排查', '我一般', '我从来',
         '实践中', '踩过', '线上', '排查过', '事后复盘', '当时']
    - weight: 15
      why: 边界与代价——说清楚「什么时候不该用」，而不只是「怎么用」
      phrases:
        ['取舍', '权衡', '代价', '什么时候不', '不该', '别用', '不推荐', '不适合',
         '局限', '限制是', '缺点', '成本是', '换来的', '副作用是', '并不']
  thresholds:
    # 一句里四个以上顿号：在罗列疆域，而不是对它说出任何判断。
    nounListMarks: 4
    nounListWeight: 5
    nounListCap: 15
    # 代码占比超过这个数，散文通常是填充物。
    codeRatio: 0.5
    # 首段显示列宽上限——超了通常意味着结论没有前置。
    openerWidth: 400
    openerWeight: 5
---

## 这个站怎么写

TODO 用几段话写清楚这个站的语气。这一半是给**写作的 agent** 读的——它决定语感，
脚本读不懂。留着这段 TODO，等于每篇文章都是照着空气写的。

值得写进来的通常有：

- 结论放在哪里，铺垫要不要
- 读者是谁，什么可以默认他们已经知道
- 什么算证据（数字？一手经历？源码？）
- 什么绝对不写

### 改写对照

TODO 给一对「差 → 好」的例子。这是整份文件里最有用的部分：抽象的语气描述容易
各自理解，一对具体的改写没有歧义。

✗ TODO 一句你不想看到的写法

✓ TODO 同一件事你希望的写法

---

## 怎么改这份文件

frontmatter 里的 `signals` 是给 `pnpm analyze` 读的——它只能识别机械痕迹：套话、
名词罗列、缺少第一手经验。上面的正文是给 agent 读的。

两者是分工，不是重复：短语表永远判断不了「这段话有没有信息量」，正文也永远变不成
退出码。想让某个词不再被扣分，就从 `avoid` 里删掉它；想换一种口吻，就改正文。

风格分数**不阻断发布**（`site/policy.yaml` 的 `style.minScore` 默认为 null）。
它是一个指向「这几段值得重写」的指针，不是判决。

完整示例：`examples/agent-native-engineer/site/voice.md`
