# frozen_string_literal: true

load File.join(__dir__, 'xapi', 'response.rb')

module Cisco; end
module CollaborationEndpoint; end

class Cisco::CollaborationEndpoint::Ui
    include ::Orchestrator::Constants

    descriptive_name 'Cisco UI'
    generic_name :CiscoUI
    implements :logic
    description 'Cisco Touch 10 UI extensions'


    # ------------------------------
    # Module callbacks

    def on_load
        on_update
    end

    def on_unload
        clear_extensions
        unbind
    end

    def on_update
        codec_mod = setting(:codec) || :VidConf
        ui_layout = setting(:cisco_ui_layout)
        bindings  = setting(:cisco_ui_bindings) || {}

        # Allow UI layouts to be stored as JSON
        if ui_layout.is_a? Hash
            logger.warn 'attempting experimental UI layout conversion'
            # FIXME: does not currently work if keys are missing from generated
            # xml (even if they are blank). Endpoints appear to ignore any
            # layouts that do not match the expected structure perfectly.
            ui_layout = (ui_layout[:Extensions] || ui_layout).to_xml \
                root:          :Extensions,
                skip_types:    true,
                skip_instruct: true
        end

        bind(codec_mod) do
            deploy_extensions 'ACA', ui_layout if ui_layout
            bindings.each { |id, config| link_widget id, config }
        end
    end


    # ------------------------------
    # Deployment

    # Push a UI definition build with the in-room control editor to the device.
    def deploy_extensions(id, xml_def)
        codec.xcommand 'UserInterface Extensions Set', xml_def, ConfigId: id
    end

    # Retrieve the extensions currently loaded.
    def list_extensions
        codec.xcommand 'UserInterface Extensions List'
    end

    # Clear any deployed UI extensions.
    def clear_extensions
        codec.xcommand 'UserInterface Extensions Clear'
    end


    # ------------------------------
    # Panel interaction

    def close_panel
        codec.xcommand 'UserInterface Extensions Panel Close'
    end

    def on_extensions_panel_clicked(event)
        id = event[:PanelId]

        logger.debug { "#{id} opened" }

        self[:__active_panel] = id
    end

    # FIXME: at the time of writing, the device API does not provide the ability
    # to monitor for user initiated panel close events. When available, track
    # these and update self[:__active_panel] accordingly.


    # ------------------------------
    # Element interaction

    # Set the value of a widget.
    def set(id, value)
        case value
        when nil
            return unset id
        when true, false
            # FIXME: the can result in an error being logged due to the inital
            # type mismatch - need a neater way to handle loss of info
            return switch(id, value).catch { highlight id, value }
        end

        logger.debug { "setting #{id} to #{value}" }

        update = codec.xcommand 'UserInterface Extensions Widget SetValue',
                                WidgetId: id, Value: value

        # The device does not raise an event when a widget state is changed via
        # the API. In these cases, ensure locally tracked state remains valid.
        update.then do
            # Ensure the value maps to the same as those recevied in responses
            self[id] = ::Cisco::CollaborationEndpoint::Xapi::Response.convert value
        end
    end

    # Clear the value associated with a widget.
    def unset(id)
        logger.debug { "clearing #{id}" }

        update = codec.xcommand 'UserInterface Extensions Widget UnsetValue',
                                WidgetId: id

        update.then { self[id] = nil }
    end

    # Set the state of a switch widget.
    def switch(id, state = !self[id])
        value = is_affirmative?(state) ? :on : :off
        set id, value
    end

    # Set the highlight state for a button widget.
    def highlight(id, state = true, momentary: false, time: 500)
        value = is_affirmative?(state) ? :active : :inactive
        set id, value
        schedule.in(time) { highlight id, !value } if momentary
    end

    # Set the text label used on text or spinner widget.
    alias label set

    # Callback for changes to widget state.
    def on_extensions_widget_action(event)
        id, value, type = event.values_at :WidgetId, :Value, :Type

        logger.debug { "#{id} #{type}" }

        id   = id.to_sym
        type = type.to_sym

        # Track values of stateful widgets
        self[id] = value unless ['', :increment, :decrement].include? value

        # Trigger any bindings defined for the widget action
        begin
            handler = event_handlers.fetch [id, type], nil
            handler&.call value
        rescue => e
            logger.error "error in binding for #{id}.#{type}: #{e}"
        end

        # Provide an event stream for other modules to subscribe to
        self[:__event_stream] = { id: id, type: type, value: value }.freeze
    end

    # Allow the all widget state to be interacted with externally as though
    # is was local status vars by using []= and [] to set and get.
    # FIXME: this cause []= to be exposed as an API method
    def []=(status, value)
        if caller_locations.map(&:path).include? __FILE__
            # Internal use follows standard behaviour provided by Core::Mixin
            @__config__.trak(status.to_sym, value)
            # FIXME: setting to nil does not remove from status - need delete
        else
            set status, value
        end
    end


    # ------------------------------
    # Popup messages

    def alert(text, title: '', duration: 0)
        codec.xcommand 'UserInterface Message Alert Display',
                       Text: text,
                       Title: title,
                       Duration: duration
    end

    def clear_alert
        codec.xcommand 'UserInterface Message Alert Clear'
    end


    protected


    # ------------------------------
    # Internals

    # Bind to a Cisco CE device module.
    #
    # @param mod [Symbol] the id of the Cisco CE device module to bind to
    def bind(mod)
        logger.debug { "binding to #{mod}" }

        @codec_mod = mod.to_sym

        clear_events
        clear_subscriptions

        @subscriptions = []

        @subscriptions << system.subscribe(@codec_mod, :connected) do |notify|
            next unless notify.value
            subscribe_events
            yield if block_given?
            sync_widget_state
        end

        @codec_mod
    end

    # Unbind from the device module.
    def unbind
        logger.debug 'unbinding'

        clear_subscriptions

        clear_events async: true

        @codec_mod = nil
    end

    def bound?
        @codec_mod.nil?.!
    end

    def codec
        raise 'not currently bound to a codec module' unless bound?
        system[@codec_mod]
    end

    # Push the current module state to the device.
    def sync_widget_state
        @__config__.status.each do |key, value|
            # Non-widget related status prefixed with `__`
            next if key =~ /^__.*/
            set key, value
        end
    end

    # Build a list of all callback methods that have been defined.
    #
    # Callback methods are denoted being single arity and beginning with `on_`.
    def ui_callbacks
        public_methods(false).each_with_object([]) do |name, callbacks|
            next if ::Orchestrator::Core::PROTECTED[name]
            next unless name[0..2] == 'on_'
            next unless method(name).arity == 1
            callbacks << name
        end
    end

    # Build a list of device XPath -> callback mappings.
    def event_mappings
        ui_callbacks.map do |cb|
            path = "/Event/UserInterface/#{cb[3..-1].tr! '_', '/'}"
            [path, cb]
        end
    end

    # Perform an action for each event -> callback mapping.
    def each_mapping(async: false)
        device_mod = codec

        interactions = event_mappings.map do |path, cb|
            yield path, cb, device_mod
        end

        result = thread.finally interactions
        result.value unless async
    end

    def subscribe_events(**opts)
        mod_id = @__config__.settings.id

        each_mapping(**opts) do |path, cb, codec|
            codec.on_event path, mod_id, cb
        end
    end

    def clear_events(**opts)
        @event_handlers = nil

        each_mapping(**opts) do |path, _, codec|
            codec.clear_event path
        end
    end

    def clear_subscriptions
        @subscriptions&.each { |ref| unsubscribe ref }
        @subscriptions = nil
    end

    def event_handlers
        @events_handlers ||= {}
    end

    # Wire up a widget based on a binding target.
    def link_widget(id, bindings)
        logger.debug { "setting up bindings for #{id}" }

        id = id.to_sym

        if bindings.is_a? String
            bindings = [:clicked, :changed, :status].product([bindings]).to_h
        end

        bindings.each do |type, target|
            type = type.to_sym

            # Status / feedback state binding
            if type == :status
                case target
                # "mod.status"
                when String
                    mod, state = target.split '.'
                    link_feedback id, mod, state

                # mod => status (provided for compatability with event bindings)
                when Hash
                    mod, state = target.first
                    link_feedback id, mod, state

                else
                    logger.warn { "invalid #{type} binding for #{id}" }
                end

            # Event binding
            else
                handler = build_handler target
                if handler
                    event_handlers.store [id, type].freeze, handler
                else
                    logger.warn { "invalid #{type} binding for #{id}" }
                end
            end
        end
    end

    # Bind a widget to another modules status var for feedback.
    def link_feedback(id, mod, state)
        logger.debug { "linking #{id} state to #{mod}.#{state}" }

        @subscriptions << system.subscribe(mod, state) do |notify|
            set id, notify.value
        end
    end

    # Given the action for a binding, construct the executable event handler.
    def build_handler(action)
        case action

        # Implicit arguments
        # "mod.method"
        when String
            mod, method = action.split '.'
            proc do |value|
                logger.debug { "proxying event to #{mod}.#{method}" }
                proxy = system[mod]
                args  = proxy.arity(method).zero? ? nil : value
                proxy.send method, *args
            end

        # Explicit / static arguments
        # mod => { method => [params] }
        when Hash
            mod, command = action.first
            method, args = command.first
            proc do
                logger.debug { "proxying event to #{mod}.#{method}" }
                system[mod].send method, *args
            end
        end
    end
end
