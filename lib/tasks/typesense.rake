# frozen_string_literal: true

desc "Rebuild the Typesense index into a fresh collection and swap the alias"
task "typesense:rebuild" => :environment do
  TypesenseIndexer.rebuild!
  puts "Typesense index rebuilt"
end
