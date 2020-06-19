# frozen_string_literal: true

load File.join(__dir__, 'component_manager.rb')

module Aca; end
module Aca::Rooms; end

class Aca::Rooms::Base
    include ::Orchestrator::Constants
    include ::Aca::Rooms::ComponentManager

    generic_name :System
    implements   :logic

    def self.setting(hash)
        previous = @default_settings || {}
        default_settings previous.merge hash
    end

    # ------------------------------
    # Callbacks

    def on_load
        on_update
    end

    def on_update
        self[:name] = system.name
        self[:type] = self.class.name.demodulize

        @config = Hash.new do |h, k|
            h[k] = setting(k) || default_setting[k]
        end
    end

    protected

    def default_setting
        self.class.instance_variable_get :@default_settings
    end

    attr_reader :config
end
