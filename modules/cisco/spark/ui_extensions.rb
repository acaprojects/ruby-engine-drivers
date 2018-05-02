# frozen_string_literal: true

module Cisco; end
module Cisco::Spark; end

module Cisco::Spark::UiExtensions
    include ::Cisco::Spark::Xapi::Mapper

    module Hooks
        def connected
            super
            register_feedback '/Event/UserInterface/Extensions/Widget/Action' do |action|
                logger.debug action
            end
        end
    end

    def self.included(base)
        base.prepend Hooks
    end

    command 'UserInterface Message Alert Clear' => :msg_alert_clear
    command 'UserInterface Message Alert Display' => :msg_alert,
            Text: String,
            Title_: String,
            Duration_: (0..3600)

    command 'UserInterface Message Prompt Clear' => :msg_prompt_clear
    def msg_prompt(text, options, title: nil, feedback_id: nil, duration: nil)
        # TODO: return a promise, then prepend a async traffic monitor so it
        # can be resolved with the response, or rejected after the timeout.
        send_xcommand \
            'UserInterface Message Prompt Display',
            {
                Text: text,
                Title: title,
                FeedbackId: feedback_id,
                Duration: duration
            }.merge(Hash[('Option.1'..'Option.5').map(&:to_sym).zip options])
    end

    command 'UserInterface Message TextInput Clear' => :msg_text_clear
    command 'UserInterface Message TextInput Display' => :msg_text,
            Text: String,
            FeedbackId: String,
            Title_: String,
            Duration_: (0..3600),
            InputType_: [:SingleLine, :Numeric, :Password, :PIN],
            KeyboardState_: [:Open, :Closed],
            PlaceHolder_: String,
            SubmitText_: String

    def ui_set_value(widget, value)
        if value.nil?
            send_xcommand 'UserInterface Extensions Widget UnsetValue',
                          WidgetId: widget
        else
            send_xcommand 'UserInterface Extensions Widget SetValue',
                          Value: value, WidgetId: widget
        end
    end

    protected

    def ui_extensions_list
        send_xcommand 'UserInterface Extensions List'
    end

    def ui_extensions_clear
        send_xcommand 'UserInterface Extensions Clear'
    end
end
