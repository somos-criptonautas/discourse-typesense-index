# frozen_string_literal: true

# The one rule that matters: nothing an anonymous visitor can't read ends up in Typesense.
RSpec.describe TypesenseIndexer do
  before { SiteSetting.typesense_indexer_enabled = true }

  let(:post) { Fabricate(:post) }

  it "indexes public posts" do
    expect(described_class.indexable?(post)).to eq(true)
    expect(described_class.document(post)).to include(id: post.id.to_s, topic_id: post.topic_id)
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
  before { SiteSetting.typesense_indexer_enabled = true }

  it "skips a requested rebuild when a later one already started" do
    Discourse.redis.set(TypesenseIndexer::REBUILD_STARTED_KEY, 200)
    expect(TypesenseIndexer).not_to receive(:rebuild!)
    described_class.new.execute(requested_at: 100)
  end

  it "rebuilds when requested after the last start, and on schedule" do
    Discourse.redis.set(TypesenseIndexer::REBUILD_STARTED_KEY, 100)
    expect(TypesenseIndexer).to receive(:rebuild!).twice
    described_class.new.execute(requested_at: 200)
    described_class.new.execute({})
  end
end
