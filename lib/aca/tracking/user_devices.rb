# frozen_string_literal: true

module Aca; end
module Aca::Tracking; end

class Aca::Tracking::UserDevices < CouchbaseOrm::Base
    design_document :userdevices

    attribute :username, :domain, type: String
    attribute :macs, type: Array, default: lambda { [] }
    attribute :updated_at, type: Integer, default: lambda { Time.now }

    index_view :macs,   find_method: :associated_with, validate: false
    index_view :domain, validate: false

    def add(mac)
        mac = format(mac)

        # Ensure this is the only user associated with the mac
        self.class.with_mac(mac).to_a
            .reject { |u| u.id == self.id }
            .each { |u| u.remove(mac) }

        self.class.bucket.set("macuser-#{mac}", username)
        return if self.macs.include?(mac)

        # Order the list last seen mac first
        # Limit the number of mac addresses to 5
        self.macs_will_change!
        self.macs.delete(mac)
        self.macs.unshift(mac)
        self.macs.pop if self.macs.length > 5
        self.save!
    rescue ::Libcouchbase::Error::KeyExists
        self.reload
        retry
    end

    def remove(mac)
        mac = format(mac)
        self.class.bucket.delete("macuser-#{mac}")

        self.macs_will_change!
        self.macs.delete(mac)
        self.save!
    rescue ::Libcouchbase::Error::KeyExists
        self.reload
        retry
    end

    def has?(mac)
        self.macs.include?(format(mac))
    end

    def self.with_mac(mac)
        associated_with(format(mac))
    end

    def self.on_domain(domain)
        find_by_domain(domain.downcase)
    end

    def self.for_user(username, domain = nil)
        macs = find_by_id("userdevices-#{username.downcase}")
        return macs if macs
        macs = self.new
        macs.username = username
        macs.domain = domain.downcase if domain
        macs
    end

    protected

    before_create :set_id
    def set_id
        self.id = "userdevices-#{self.username.downcase}"
    end

    before_save :update_timestamp
    def update_timestamp
        self.updated_at = Time.now
    end

    before_destroy :remove_macs
    def remove_macs
        self.macs.each do |mac|
            self.class.bucket.delete("macuser-#{mac}")
        end
    end

    def self.format(mac)
        mac.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
    end

    def format(mac)
        self.class.format(mac)
    end
end
