# frozen_string_literal: true

# The one rule that matters: nothing an anonymous visitor can't read ends up in Typesense.
RSpec.describe TypesenseIndexer do
  before { SiteSetting.typesense_indexer_enabled = true }

  let(:post) { Fabricate(:post) }

  it "indexes public posts" do
    expect(described_class.indexable?(post)).to eq(true)
    expect(described_class.document(post)).to include(id: post.id.to_s, topic_id: post.topic_id)
  end

  it "sends the topic image as an absolute URL and the category's colour and icon" do
    category = Fabricate(:category, color: "f5c211", style_type: "icon", icon: "bitcoin")
    upload = Fabricate(:image_upload)
    post.topic.update!(category: category, image_upload: upload)
    doc = described_class.document(post.reload)
    expect(doc[:image]).to start_with("http").and end_with(upload.url.split("/").last)
    expect(doc).to include(category_color: "f5c211", category_icon: "bitcoin", category_image: "")
    category.update!(uploaded_logo: Fabricate(:image_upload))
    expect(described_class.document(post.reload)[:category_image]).to start_with("http")
    expect(described_class.document(Fabricate(:post))[:image]).to eq("")
  end

  it "files a post under its detected language, else the site's" do
    SiteSetting.default_locale = "es"
    expect(described_class.document(post)[:locale]).to eq("es")
    post.update_columns(locale: "pt_BR")
    expect(described_class.document(post.reload)[:locale]).to eq("pt")
  end

  it "skips read-restricted categories" do
    category = Fabricate(:private_category, group: Fabricate(:group))
    post.topic.update!(category: category)
    expect(described_class.indexable?(post.reload)).to eq(false)
  end

  it "skips private messages" do
    expect(described_class.indexable?(Fabricate(:private_message_post))).to eq(false)
  end

  it "skips whispers, hidden, deleted and unlisted" do
    expect(described_class.indexable?(Fabricate(:post, post_type: Post.types[:whisper]))).to eq(
      false,
    )
    expect(described_class.indexable?(Fabricate(:post, hidden: true))).to eq(false)
    post.topic.update!(visible: false)
    expect(described_class.indexable?(post.reload)).to eq(false)
  end

  it "skips excluded categories and their subcategories" do
    parent = Fabricate(:category)
    post.topic.update!(category: Fabricate(:category, parent_category: parent))
    SiteSetting.typesense_excluded_categories = parent.id.to_s
    expect(described_class.indexable?(post.reload)).to eq(false)
  end

  it "skips short replies but keeps short first posts" do
    SiteSetting.typesense_min_reply_length = 50
    first = Fabricate(:post, raw: "Short opening post here")
    reply = Fabricate(:post, topic: first.topic, raw: "Short reply, still too short")
    expect(described_class.indexable?(first)).to eq(true)
    expect(described_class.indexable?(reply)).to eq(false)
  end

  it "skips everything on login-required sites" do
    SiteSetting.login_required = true
    expect(described_class.indexable?(post)).to eq(false)
  end

  it "leaves out tags hidden from anonymous visitors" do
    create_hidden_tags(["staff-only"])
    post.topic.tags = [Fabricate(:tag, name: "public"), Tag.find_by(name: "staff-only")]
    expect(described_class.document(post.reload)[:tags]).to contain_exactly("public")
  end
end

RSpec.describe Jobs::TypesenseRebuild do
  before do
    SiteSetting.typesense_indexer_enabled = true
    allow(TypesenseIndexer).to receive(:rebuild!)
  end

  it "skips a requested rebuild when a later one already started" do
    Discourse.redis.set(TypesenseIndexer::REBUILD_STARTED_KEY, 200)
    described_class.new.execute(requested_at: 100)
    expect(TypesenseIndexer).not_to have_received(:rebuild!)
  end

  it "rebuilds when requested after the last start, and on schedule" do
    Discourse.redis.set(TypesenseIndexer::REBUILD_STARTED_KEY, 100)
    described_class.new.execute(requested_at: 200)
    described_class.new.execute({})
    expect(TypesenseIndexer).to have_received(:rebuild!).twice
  end
end

# A category save used to rebuild the whole index, which re-embeds every post on the forum.
RSpec.describe TypesenseIndexer, ".sync_category" do
  before { SiteSetting.typesense_indexer_enabled = true }

  let(:client) { instance_double(TypesenseIndexer::Client, delete_where: nil, import: nil) }

  before { allow(TypesenseIndexer).to receive(:client).and_return(client) }

  it "re-checks the category and its subcategories, and nothing else" do
    parent = Fabricate(:category)
    child = Fabricate(:category, parent_category_id: parent.id)
    elsewhere = Fabricate(:category)

    here = Fabricate(:post)
    here.topic.update!(category: parent)
    nested = Fabricate(:post)
    nested.topic.update!(category: child)
    other = Fabricate(:post)
    other.topic.update!(category: elsewhere)

    TypesenseIndexer.sync_category(parent.id)

    expect(client).to have_received(:delete_where).with(
      TypesenseIndexer.collection,
      "category_id:[#{parent.id},#{child.id}]",
    )
    expect(client).to have_received(:import) do |_collection, docs|
      ids = docs.map { |d| d[:id] }
      expect(ids).to include(here.id.to_s, nested.id.to_s)
      expect(ids).not_to include(other.id.to_s)
    end
  end
end

# Changes that take content away from anonymous visitors without any event the index listens to.
RSpec.describe Post do
  before { SiteSetting.typesense_indexer_enabled = true }

  fab!(:topic)
  fab!(:first_post) { Fabricate(:post, topic: topic) }
  fab!(:reply) { Fabricate(:post, topic: topic) }

  it "re-syncs a reply when it is hidden or unhidden" do
    expect_enqueued_with(job: :typesense_sync, args: { post_id: reply.id }) do
      reply.hide!(PostActionType.types[:spam])
    end
    expect_enqueued_with(job: :typesense_sync, args: { post_id: reply.id }) { reply.unhide! }
  end

  it "rebuilds when the site starts requiring login" do
    expect_enqueued_with(job: :typesense_rebuild) { SiteSetting.login_required = true }
  end
end
