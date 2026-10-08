# frozen_string_literal: true

module ::TypesenseIndexer
  BATCH_SIZE = 1000
  REBUILD_STARTED_KEY = "typesense_indexer_rebuild_started_at"

  FIELDS = [
    { name: "topic_id", type: "int64", facet: true },
    { name: "post_number", type: "int32" },
    { name: "title", type: "string" },
    { name: "text", type: "string" },
    { name: "url", type: "string", index: false, optional: true },
    { name: "username", type: "string", facet: true },
    { name: "category_id", type: "int64", facet: true },
    { name: "category", type: "string", facet: true },
    { name: "tags", type: "string[]", facet: true },
    { name: "like_count", type: "int32" },
    # ponytail: denormalised, so a reply only refreshes its own doc and sibling docs keep
    # the old count until the topic is re-synced or the daily rebuild runs. It is a hint
    # next to a search result, not a counter - re-importing every post of a hot topic on
    # each reply would cost far more than the staleness.
    { name: "reply_count", type: "int32" },
    { name: "created_at", type: "int64" },
  ].freeze

  # Semantic search. Typesense embeds title and text itself at import time, and each query
  # at search time - nothing is sent from here, the field's `embed` block is the whole
  # integration. A collection's fields are fixed when it is created, so this only takes
  # effect on a rebuild, which changing any typesense_ setting already triggers (plugin.rb).
  def self.fields
    config = embedding_model_config
    return FIELDS if config.nil?

    field = {
      name: "embedding",
      type: "float[]",
      optional: true,
      embed: {
        from: %w[title text],
        model_config: config,
      },
    }
    # Discourse asks the provider for a shortened vector when the definition says so;
    # num_dim makes Typesense send the same `dimensions` parameter.
    defn = @embedding_definition
    field[:num_dim] = defn.dimensions if defn.matryoshka_dimensions
    FIELDS + [field]
  end

  # The embedding definition picked in typesense_embedding_definition is one of Discourse
  # AI's own, so the URL, model and credential - including an AiSecret - stay in one place.
  # Typesense keeps a copy of the key in the collection schema to embed queries; a rotated
  # key reaches it on the next rebuild (daily, or resave the setting to force one).
  def self.embedding_model_config
    @embedding_definition = nil
    id = SiteSetting.typesense_embedding_definition.to_s.strip
    return if id.empty? || !defined?(::EmbeddingDefinition)

    defn = ::EmbeddingDefinition.find_by(id: id)
    return if defn.nil?

    model = defn.lookup_custom_param("model_name").to_s.strip
    # Typesense only reaches remote models through OpenAI's API shape.
    if defn.provider != ::EmbeddingDefinition::OPEN_AI || model.empty?
      Rails.logger.warn(
        "[typesense] embedding definition #{defn.id} (#{defn.provider}) is not an " \
          "OpenAI-compatible model; indexing without embeddings",
      )
      return
    end

    # Discourse stores the full endpoint; Typesense wants it as base URL + path.
    uri = URI.parse(defn.endpoint_url)
    base = "#{uri.scheme}://#{uri.host}"
    base += ":#{uri.port}" if uri.port != uri.default_port
    path = uri.path.delete_prefix("/")
    path += "?#{uri.query}" if uri.query.present?

    config = {
      # Typesense strips only the first segment, so "openai/BAAI/bge-m3" reaches the
      # provider as "BAAI/bge-m3".
      model_name: "openai/#{model}",
      api_key: defn.api_key.to_s,
      url: base,
      path: path,
    }
    # Same prompts Discourse puts in front, joined with a space as Discourse does.
    config[:query_prefix] = "#{defn.search_prompt} " if defn.search_prompt.present?
    config[:indexing_prefix] = "#{defn.embed_prompt} " if defn.embed_prompt.present?

    @embedding_definition = defn
    config
  end

  def self.client
    # a pasted key or URL often carries a trailing space or newline; Typesense answers 401
    Client.new(SiteSetting.typesense_url.strip, SiteSetting.typesense_api_key.strip)
  end

  def self.collection
    SiteSetting.typesense_collection
  end

  # Only what an anonymous visitor can read. Guardian already rules out read-restricted
  # categories, PMs, shared drafts, deleted/hidden posts, whispers, and whatever plugins
  # add to it (category lockdown hides paywalled categories this way).
  def self.indexable?(post, guardian = Guardian.new)
    return false if SiteSetting.login_required
    return false if post.post_type != Post.types[:regular]
    return false if !post.topic&.visible # unlisted topics are reachable by link only

    category = post.topic.category
    excluded = SiteSetting.typesense_excluded_categories_map
    return false if category && (excluded & [category.id, category.parent_category_id]).any?

    # the title gives a first post its meaning, so only replies need a minimum length
    if post.post_number > 1 && post.raw.to_s.strip.length < SiteSetting.typesense_min_reply_length
      return false
    end

    guardian.can_see_post?(post)
  end

  def self.document(post, hidden_tags = DiscourseTagging.hidden_tag_names)
    topic = post.topic
    {
      id: post.id.to_s,
      topic_id: topic.id,
      post_number: post.post_number,
      title: topic.title,
      text: SearchIndexer::HtmlScrubber.scrub(post.cooked),
      url: post.full_url,
      username: post.user&.username.to_s,
      category_id: topic.category_id.to_i,
      category: topic.category&.name.to_s,
      tags: topic.tags.map(&:name) - hidden_tags,
      like_count: post.like_count,
      reply_count: [topic.posts_count - 1, 0].max,
      created_at: post.created_at.to_i,
    }
  end

  def self.import(target, posts, c = client)
    guardian = Guardian.new
    hidden_tags = DiscourseTagging.hidden_tag_names
    docs = posts.select { |p| indexable?(p, guardian) }.map { |p| document(p, hidden_tags) }
    c.import(target, docs)
  end

  def self.sync_post(post_id)
    post = posts_scope(Post).find_by(id: post_id)
    if post && indexable?(post)
      client.import(collection, [document(post)])
    else
      client.delete(collection, post_id)
    end
  end

  # ponytail: delete-then-import leaves the topic out of results for a moment; fine for search.
  def self.sync_topic(topic_id)
    c = client
    c.delete_where(collection, "topic_id:=#{topic_id.to_i}")
    posts_scope(Post.where(topic_id: topic_id)).find_in_batches(batch_size: BATCH_SIZE) do |posts|
      import(collection, posts, c)
    end
  end

  def self.last_rebuild_started_at
    Discourse.redis.get(REBUILD_STARTED_KEY).to_i
  end

  # Full rebuild into a fresh collection, then an atomic alias swap: searches never see a
  # half-built index, and anything the live sync missed (deletions, permission changes,
  # renamed users) is corrected.
  def self.rebuild!
    c = client
    started_at = Time.zone.now
    Discourse.redis.set(REBUILD_STARTED_KEY, started_at.to_i)
    fresh = "#{collection}_#{started_at.to_i}"

    c.create_collection(name: fresh, fields: fields, default_sorting_field: "created_at")
    begin
      scope =
        Post.joins(:topic).where(
          post_type: Post.types[:regular],
          hidden: false,
          topics: {
            archetype: Archetype.default,
            visible: true,
            deleted_at: nil,
          },
        )
      posts_scope(scope).find_in_batches(batch_size: BATCH_SIZE) { |posts| import(fresh, posts, c) }
    rescue StandardError
      c.drop_collection(fresh)
      raise
    end

    c.point_alias(collection, fresh)

    # the previous collection, plus any left behind by a rebuild that was killed mid-way
    # ponytail: a manual rake rebuild running at the same moment would lose its collection; rerun it.
    stale = /\A#{Regexp.escape(collection)}_\d+\z/
    c.collections.each { |name| c.drop_collection(name) if name != fresh && name.match?(stale) }

    # Live syncs during the rebuild wrote to the old collection; replay them.
    Topic
      .with_deleted
      .where("updated_at >= :t OR deleted_at >= :t", t: started_at)
      .pluck(:id)
      .each { |id| sync_topic(id) }
    Post
      .with_deleted
      .where("updated_at >= :t OR deleted_at >= :t", t: started_at)
      .pluck(:id)
      .each { |id| sync_post(id) }
  end

  def self.posts_scope(scope)
    scope.includes(:user, topic: %i[category tags])
  end
end

module ::Jobs
  class TypesenseSync < ::Jobs::Base
    sidekiq_options queue: "low"

    def execute(args)
      return if !SiteSetting.typesense_indexer_enabled

      if args[:topic_id]
        ::TypesenseIndexer.sync_topic(args[:topic_id])
      else
        ::TypesenseIndexer.sync_post(args[:post_id])
      end
    end
  end

  class TypesenseRebuild < ::Jobs::Scheduled
    every 1.day
    cluster_concurrency 1

    def execute(args)
      return if !SiteSetting.typesense_indexer_enabled
      # several changes in a row queue several rebuilds; one that started later already saw them
      if args[:requested_at] &&
           args[:requested_at].to_i < ::TypesenseIndexer.last_rebuild_started_at
        return
      end
      ::TypesenseIndexer.rebuild!
    end
  end
end
