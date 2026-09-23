# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# Plain-stdlib Typesense HTTP client: only the calls the indexer needs.
module TypesenseIndexer
  class Client
    class Error < StandardError
    end

    def initialize(url, api_key)
      @uri = URI(url)
      @api_key = api_key
    end

    def import(collection, docs)
      return if docs.empty?
      body = docs.map { |d| JSON.generate(d) }.join("\n")
      res =
        request(Net::HTTP::Post, "/collections/#{collection}/documents/import?action=upsert", body)
      # Typesense answers 200 even when single documents fail
      failed = res.body.lines.map { |l| JSON.parse(l) }.reject { |r| r["success"] }
      raise Error, "import into #{collection} failed: #{failed.first(3)}" if failed.any?
    end

    def delete(collection, id)
      request(Net::HTTP::Delete, "/collections/#{collection}/documents/#{id}", allow_404: true)
    end

    def delete_where(collection, filter)
      q = URI.encode_www_form(filter_by: filter)
      request(Net::HTTP::Delete, "/collections/#{collection}/documents?#{q}")
    end

    def collections
      JSON.parse(request(Net::HTTP::Get, "/collections").body).map { |c| c["name"] }
    end

    def create_collection(schema)
      request(Net::HTTP::Post, "/collections", JSON.generate(schema))
    end

    def drop_collection(name)
      request(Net::HTTP::Delete, "/collections/#{name}", allow_404: true)
    end

    def point_alias(name, collection)
      request(Net::HTTP::Put, "/aliases/#{name}", JSON.generate(collection_name: collection))
    end

    private

    def request(klass, path, body = nil, allow_404: false)
      req = klass.new("#{@uri.path.chomp("/")}#{path}") # keeps a proxy prefix like /typesense
      req["X-TYPESENSE-API-KEY"] = @api_key
      req["Content-Type"] = "application/json"
      req.body = body if body

      res =
        Net::HTTP.start(
          @uri.host,
          @uri.port,
          nil, # no proxy: Net::HTTP would otherwise route via http_proxy from the environment
          use_ssl: @uri.scheme == "https",
          open_timeout: 5,
          read_timeout: 120,
        ) { |http| http.request(req) }

      return nil if allow_404 && res.code == "404"
      raise Error, "#{req.method} #{path}: #{res.code} #{res.body}" if !res.is_a?(Net::HTTPSuccess)
      res
    end
  end
end

# Self-check against a throwaway Typesense (CI runs this too):
#   docker run --rm -p 8108:8108 typesense/typesense:29.0 --data-dir /tmp --api-key=xyz
#   ruby lib/typesense_indexer/client.rb
if __FILE__ == $PROGRAM_NAME
  c =
    TypesenseIndexer::Client.new(
      ENV.fetch("TYPESENSE_URL", "http://localhost:8108"),
      ENV.fetch("TYPESENSE_API_KEY", "xyz"),
    )
  fields = [{ name: "topic_id", type: "int64" }, { name: "text", type: "string" }]
  c.create_collection(name: "check_a", fields: fields)
  c.point_alias("check", "check_a")
  raise "collections" if !c.collections.include?("check_a")
  c.import(
    "check",
    [{ id: "1", topic_id: 7, text: "hola" }, { id: "2", topic_id: 8, text: "chao" }],
  )
  c.import("check", [{ id: "1", topic_id: 7, text: "hola de nuevo" }]) # upsert
  c.delete("check", "2")
  c.delete("check", "404") # missing doc is fine
  c.delete_where("check", "topic_id:=7")
  begin
    c.import("check", [{ id: "3", topic_id: "not a number", text: "x" }])
    raise "bad doc should fail"
  rescue TypesenseIndexer::Client::Error
  end
  c.drop_collection("check_a")
  c.drop_collection("check_a") # already gone is fine
  puts "client ok"
end
