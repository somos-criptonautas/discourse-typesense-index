# discourse-typesense-index

**ENGLISH** | [ESPAÑOL](README.es.md)

Keeps a self-hosted Typesense collection in sync with the Discourse posts an anonymous
visitor can read. No search UI, no proxy, no gems. You search from your own frontend.

## What gets indexed

One document per public post (`id` = post id):
`topic_id, post_number, title, text, url, username, category_id, category, tags, like_count, created_at`.

A post is indexed only if all of these hold:

- the site is not `login_required`
- it's a regular post, not a whisper or small action
- its topic is listed, not unlisted
- its category (or that category's parent) is not in `typesense_excluded_categories`
- it's a first post, or a reply at least `typesense_min_reply_length` characters long
- `Guardian.new.can_see_post?` passes. That rules out private categories, PMs, hidden or
  deleted posts, and anything plugins such as category lockdown restrict.

Tags hidden from anonymous visitors are left out of `tags`. `text` is the post scrubbed the
same way Discourse's own search does it.

## Settings

| Setting | Default | |
|---|---|---|
| `typesense_indexer_enabled` | off | master switch |
| `typesense_url` | `http://localhost:8108` | Typesense base URL, as reached from the Discourse container; a path prefix is kept |
| `typesense_api_key` | | admin key; it never leaves the server |
| `typesense_collection` | `discourse_posts` | the alias your frontend searches |
| `typesense_excluded_categories` | none | public categories to leave out; their subcategories are left out too |
| `typesense_min_reply_length` | `20` | shorter replies are skipped; first posts are always indexed |

Enabling the plugin, or changing any of these settings, starts a full rebuild.

## Searching it: one row per discussion

`url` points at the post itself (`/t/slug/<topic_id>/<post_number>`), so grouping by topic
gives each discussion's best-matching reply, with a link straight to it:

```js
{
  collection: "discourse_posts",
  q: "monero wallet",
  query_by: "title,text",
  group_by: "topic_id",
  group_limit: 1,
  highlight_fields: "text",
}
```

To show only topics, filter `post_number:=1` instead.

## How it stays in sync

- **Live:** post and topic events enqueue a `typesense_sync` job for that post or topic.
- **Rebuild:** daily, and whenever a category or a setting changes. It builds a fresh
  `<collection>_<timestamp>`, swaps the alias to it, then drops leftover collections from
  earlier or interrupted rebuilds. Searches never see a half-built index.

## Setup

1. Add to `app.yml` and rebuild:
   `- git clone https://github.com/somos-criptonautas/discourse-typesense-index.git`
2. Set `typesense_url` and `typesense_api_key`, then enable `typesense_indexer_enabled`.
   The first build starts automatically. `rake typesense:rebuild` runs one by hand.
3. Create a search-only key for the frontend:

   ```bash
   curl -X POST "$TYPESENSE_URL/keys" -H "X-TYPESENSE-API-KEY: $ADMIN_KEY" \
     -d '{"description":"search","actions":["documents:search"],"collections":["discourse_posts*"]}'
   ```

   The index holds public content only, so this key is safe to use in a browser.

## CI

`.github/workflows/discourse-plugin.yml` runs two things:

- Discourse's standard plugin workflow: rubocop, syntax_tree, and the specs inside a real
  Discourse checkout.
- The HTTP client self-check against a Typesense service container.

Locally: `ruby lib/typesense_indexer/client.rb`, and
`LOAD_PLUGINS=1 bin/rspec plugins/discourse-typesense-index/spec` from a Discourse checkout.

## License

GPL-3.0. See [LICENSE](LICENSE).

Text of this README under [CC BY-NC-SA 4.0](CC-BY-NC-SA-4.0.txt).
