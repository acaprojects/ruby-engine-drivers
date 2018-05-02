# frozen_string_literal: true

require_relative 'git'

module Cisco; end
module Cisco::Spark; end
module Cisco::Spark::Util; end

module Cisco::Spark::Util::Meta
    module_function

    def version(instance)
        hash = Cisco::Spark::Util::Git.hash __dir__
        "#{instance.class.name}-#{hash}"
    end
end
