# frozen_string_literal: true

# A full rebuild imports 1000 posts per batch; behind nginx's default 1 MB body limit a batch
# of long posts got a 413 and the rebuild aborted.
RSpec.describe TypesenseIndexer::Client do
  let(:client) { described_class.new("http://typesense:8108", "key") }
  let(:docs) { (1..1000).map { |i| { id: i.to_s, text: "x" * (300 + (i * 37) % 4000) } } }

  it "splits an import into requests that fit under the body limit, keeping every doc once" do
    bodies = []
    client.define_singleton_method(:request) do |_klass, _path, body = nil, **|
      bodies << body
      Struct.new(:body).new(body.lines.map { JSON.generate(success: true) }.join("\n"))
    end

    client.import("posts", docs)

    expect(bodies.size).to be > 1
    expect(bodies.map(&:bytesize).max).to be <= described_class::MAX_BODY_BYTES
    sent = bodies.flat_map { |b| b.lines.map { |l| JSON.parse(l)["id"] } }
    expect(sent).to eq(docs.map { |d| d[:id] })
  end
end
