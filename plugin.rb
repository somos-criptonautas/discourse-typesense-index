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

  # Hiding a flagged reply fires no event, and neither does unhiding it. Hiding a first post
  # unlists the topic, which topic_status_updated already covers.
  # Checked on save: unhide! saves twice, so saved changes are gone by commit.
  add_model_callback(:post, :after_save) do
    DB.after_commit { sync.(post_id: id) } if saved_change_to_hidden?
  end

  # Restricting a tag group hides its tag names from anonymous visitors, with no event.
  add_model_callback(:tag_group, :after_commit) { sync.(tag_group_id: id) }

  # Translations (content localization) have no event on every Discourse version, and none at
  # all for removals and topic titles, so model callbacks queue the sync. reloadable_patch
  # re-applies them when Discourse reloads its models in development.
  reloadable_patch do
    PostLocalization.class_eval do
      after_commit do
        if SiteSetting.typesense_indexer_enabled
          Jobs.enqueue(:typesense_sync, post_id: post_id, locale: locale)
        end
      end
    end

    # a translated title changes every translated document of the topic
    TopicLocalization.class_eval do
      after_commit do
        Jobs.enqueue(:typesense_sync, topic_id: topic_id) if SiteSetting.typesense_indexer_enabled
      end
    end
  end

  # Enabling the plugin, a new connection, a new embedding model, or new indexing rules.
  # Narrowing this is tempting - a rebuild re-embeds everything - but excluding a category
  # has to drop the documents already in the index, and a rebuild is the only full pass
  # there is. These settings change a few times a year; a category save is a weekly click.
  # login_required and lockdown decide what an anonymous visitor may read on every category;
  # content localization adds or removes every translated document.
  rebuild_settings = %w[login_required category_lockdown_enabled content_localization_enabled]
  on(:site_setting_changed) do |name, *|
    rebuild.() if name.to_s.start_with?("typesense_") || rebuild_settings.include?(name.to_s)
  end
end
