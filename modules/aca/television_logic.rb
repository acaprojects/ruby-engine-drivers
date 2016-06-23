
class Aca::TelevisionLogic
    include ::Orchestrator::Constants


    descriptive_name 'ACA Television Logic'
    generic_name :Television
    implements :logic


    def on_load
        on_update

        # Load the previous state
        goto(@start_channel, false) if @start_channel
    end

    def on_update
        @start_channel = setting(:start_channel)
        @tv_input = setting(:tv_input) || :hdmi

        # Update the Schedules
        begin
            # Startup schedule
            @warmup_timer.cancel if @warmup_timer
            time = setting(:power_on_time)
            if time
                @warmup_timer = schedule.cron(time) do
                    power_on_displays
                    goto(@start_channel, false) if @start_channel
                end
            end

            # Poweroff schedule
            @hardoff_timer.cancel if @hardoff_timer
            time = setting(:power_off_time)
            if time
                @hardoff_timer = schedule.cron(time) do
                    power_off_displays
                end
            end
        rescue => e
            logger.print_error(e, 'bad cron schedule configuration')
        end

        @box_id = setting(:box_id)
        @channels = setting(:channels) || {}
        self[:channelNames] = @channels.keys

        self[:name] = setting(:name)
        self[:input_list] = setting(:input_list)
    end

    def goto(channel, save = true)
        chan_id = [@channels[channel]]
        chan_id << @box_id if @box_id

        if chan_id[0]
            system[:IPTV].channel(*chan_id)
            self[:channelName] = channel
            define_setting(:start_channel, channel) if save
        else
            logger.warn "Unknown channel #{channel}"
        end
    end

    def power_on
        power_on_displays
    end

    def power_off
        system.all(:Display).power Off
    end


    protected


    def power_on_displays
        system.all(:Display).each do |display|
            if check display.arity(:power)
                # As this is UDP we send the power on request twice
                display.power On, setting(:broadcast)
                schedule.in(1 + rand(5000)) do
                    display.power On, setting(:broadcast)
                end
            else
                display.power On
            end

            display.switch_to @tv_input
        end
    end

    def power_off_displays
        system.all(:Display).each do |disp|
            if disp.respond_to? :hard_off
                disp.hard_off
            else
                disp.power Off
            end
        end
    end

    # Checks if the display support broadcasting power on
    def check(arity)
        arity >= 2 || arity < 0
    end
end
