# frozen_string_literal: true

# name: discourse-typesense-index
# about: Keeps a self-hosted Typesense collection in sync with public Discourse posts
# version: 0.1.0
# authors: Criptonautas
# url: https://github.com/somos-criptonautas/discourse-typesense-index

enabled_site_setting :typesense_indexer_enabled

after_initialize do
  require_relative "lib/typesense_indexer/client"
  require_relative "lib/typesense_indexer"

  sync = ->(**args) { Jobs.enqueue(:typesense_sync, **args) }
  rebuild = -> { Jobs.enqueue(:typesense_rebuild, requested_at: Time.now.to_i) }

  %i[post_created post_destroyed post_recovered post_owner_changed].each do |event|
    on(event) { |post, *| sync.(post_id: post.id) }
  end

  # title, category or tag edits go through the first post
  on(:post_edited) do |post, topic_changed|
    topic_changed ? sync.(topic_id: post.topic_id) : sync.(post_id: post.id)
  end

  %i[
    topic_trashed
    topic_destroyed
    topic_recovered
    topic_category_changed
    topic_published
  ].each { |event| on(event) { |topic, *| sync.(topic_id: topic.id) } }

  on(:topic_status_updated) do |topic, status|
    sync.(topic_id: topic.id) if status.to_s == "visible"
  end

  # split, merge and move all end here
  on(:posts_moved) do |destination_topic_id:, original_topic_id:, **|
    sync.(topic_id: original_topic_id)
    sync.(topic_id: destination_topic_id)
  end

  # permissions and lockdown live on the category, so its posts need re-checking - but only
  # its own subtree, not the whole forum (see sync_category)
  on(:category_updated) { |category, *| sync.(category_id: category.id) }

  # Enabling the plugin, a new connection, a new embedding model, or new indexing rules.
  # Narrowing this is tempting - a rebuild re-embeds everything - but excluding a category
  # has to drop the documents already in the index, and a rebuild is the only full pass
  # there is. These settings change a few times a year; a category save is a weekly click.
  on(:site_setting_changed) { |name, *| rebuild.() if name.to_s.start_with?("typesense_") }
end
