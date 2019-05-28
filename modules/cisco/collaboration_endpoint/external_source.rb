# frozen_string_literal: true

load File.join(__dir__, 'xapi', 'mapper.rb')

module Cisco; end
module Cisco::CollaborationEndpoint; end

module Cisco::CollaborationEndpoint::ExternalSource
    include ::Cisco::CollaborationEndpoint::Xapi::Mapper

    module Hooks
        def connected
            super
            register_feedback \
                '/Event/UserInterface/Presentation/ExternalSource' do |action|
                source = action.dig :Selected, :SourceIdentifier
                unless source.nil?
                    self[:external_source] = source
                    signal_status(:external_source)
                end
            end
        end
    end

    def self.included(base)
        base.prepend Hooks
    end

    # TODO: protect methods (via ::Orchestrator::Security) that manipulate
    # sources. Currently mapper does not support this from within a module.
    command 'UserInterface Presentation ExternalSource Add' => :add_source,
            SourceIdentifier: String,
            ConnectorId: (1..7),
            Name: String,
            Type: [:pc, :camera, :desktop, :document_camera, :mediaplayer,
                   :other, :whiteboard]

    command 'UserInterface Presentation ExternalSource Remove' => :remove_source,
            SourceIdentifier: String

    command 'UserInterface Presentation ExternalSource RemoveAll' => :clear_sources

    command 'UserInterface Presentation ExternalSource Select' => :select_source,
            SourceIdentifier: String

    command 'UserInterface Presentation ExternalSource State Set' => :source_state,
            SourceIdentifier: String,
            State: [:Error, :Hidden, :NotReady, :Ready],
            ErrorReason_: String

    command 'UserInterface Presentation ExternalSource List' => :list_sources
end
