# frozen_string_literal: true

require_relative 'case_insensitive_hash'

module Cisco; end
module Cisco::CollaborationEndpoint; end
module Cisco::CollaborationEndpoint::Util; end

class Cisco::CollaborationEndpoint::Util::FeedbackTrie < Cisco::CollaborationEndpoint::Util::CaseInsensitiveHash
    # Insert a response handler block to be notified of updates effecting the
    # specified feedback path.
    def insert(path, &handler)
        node = tokenize(path).reduce(self) do |trie, token|
            trie[token] ||= self.class.new
        end

        node << handler

        self
    end

    # Nuke a subtree below the path
    def remove(path)
        path_components = tokenize path

        if path_components.empty?
            clear
            handlers.clear
        else
            *parent_path, node_key = path_components
            parent = parent_path.empty? ? self : dig(*parent_path)
            parent&.delete node_key
        end

        self
    end

    def contains?(path)
        !dig(*tokenize(path)).nil?
    end

    # Propogate a response throughout the trie
    def notify(response)
        response.try(:each) do |key, value|
            node = self[key]
            next unless node
            node.dispatch value
            node.notify value
        end
    end

    protected

    # Append a rx handler block to this node.
    def <<(blk)
        handlers << blk
    end

    # Dispatch to all handlers registered on this node.
    def dispatch(value)
        handlers.each { |handler| handler.call value }
    end

    def tokenize(path)
        if path.is_a? Array
            path
        else
            path.split(/[\s\/\\]/).reject(&:empty?)
        end
    end

    def handlers
        @handlers ||= []
    end
end
