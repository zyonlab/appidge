# site/ — everything a person decides

This directory is the intent plane. It is YAML and Markdown on purpose: a config
file that cannot contain an import cannot slowly turn into code.
`content/` holds the articles; `engine/` holds the machinery and is not edited to
make a site decision.

## Which file does this task need

Read the one file your task needs, not the directory. Reading all of it costs
~9k tokens; a single task needs 1–2k.

| Task | File |
|---|---|
| Write an article | `voice.md` (the prose half) + `taxonomy.yaml` (valid categories) |
| Rebrand, change author/social/hero | `site.yaml` |
| Publish in a second language | `locales:` in `site.yaml`, then an `i18n:` block wherever the copy is |
| Rewrite About / Uses / Newsletter / Work-with-me | `pages.yaml` |
| Change topics, series or strategy pillars | `taxonomy.yaml` |
| Add or rename a content type, move it in the nav | `content-types.yaml` |
| Change what counts as publishable | `policy.yaml` |
| Change how the site sounds | `voice.md` |
| Restyle | `themes/*.css` + the `theme` block in `site.yaml` |

**Better than reading any of them: `pnpm context <task>`.** It prints exactly the
slice a task needs — for writing, that includes the list of existing pages you
can link to, which no config file contains.

```bash
pnpm context write     # voice, valid categories, constraints, link targets
pnpm context setup     # current brand values + what is still a placeholder
pnpm context type      # existing content types + the two-halves contract
pnpm context status    # validate + analyze + metrics merged into one to-do list
```

## Files

| File | Holds | Validated by |
|---|---|---|
| `site.yaml` | name, url, locale, `locales`, author, social, hero, services, theme choice, static nav | build — key + fix named |
| `taxonomy.yaml` | pillars, topics, series; the category vocabulary is derived from the topic keys | build — unknown pillar, dangling series, unclaimed pillar |
| `content-types.yaml` | route, label, list copy, surfaces per type | build — must pair with `engine/content-types/<name>.ts` |
| `policy.yaml` | thresholds and switches; every value has an engine default | overrides reported in the run |
| `pages.yaml` | copy for the static pages | build |
| `voice.md` | writing style — frontmatter for `pnpm analyze`, prose for the writing agent | `pnpm analyze` |
| `themes/*.css` | design token sets | rules C-12, C-13 |

## The pipeline will not run until this directory is planned

`pnpm validate` and `pnpm context write` both refuse while these files still
hold shipped defaults, across seven areas: identity, domain, copy, taxonomy,
template, voice, ai. Run `pnpm context setup` for the list.

Keeping a default deliberately is fine — add its area to
`planning.acknowledged` in `policy.yaml`, and it will be printed on every run
instead of quietly passing.

## Rules of thumb

- A value belongs here if **a different owner would choose differently and there
  is no correct answer**. If there is one correct implementation, it belongs in
  `engine/`.
- A threshold belongs in `policy.yaml`, never as a constant in `engine/`.
  Editing the constant loses the change on the next update and hides it from the
  report.
- Changing a topic key invalidates the `category` of every article using it.
  Cheapest while `content/` is small.

Full contract: [`../docs/specs/site-config-contract.md`](../docs/specs/site-config-contract.md).
Why it is shaped this way: [`../docs/adr/0002-three-planes.md`](../docs/adr/0002-three-planes.md).
