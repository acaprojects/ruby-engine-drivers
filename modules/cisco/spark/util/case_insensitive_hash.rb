# frozen_string_literal: true

require 'active_support/core_ext/hash/indifferent_access'

module Cisco; end
module Cisco::Spark; end
module Cisco::Spark::Util; end

class Cisco::Spark::Util::CaseInsensitiveHash < \
        ActiveSupport::HashWithIndifferentAccess
    def [](key)
        super convert_key(key)
    end

    protected

    def convert_key(key)
        super(key.try(:downcase) || key)
    end
end
