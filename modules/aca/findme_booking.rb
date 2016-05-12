module Aca; end

# NOTE:: Requires Settings:
# ========================
# room_alias: 'rs.au.syd.L16Aitken',
# building: 'DP3',
# level: '16'

class Aca::FindmeBooking
    include ::Orchestrator::Constants


    descriptive_name 'Findme Room Bookings'
    generic_name :Bookings
    implements :logic


    # The room we are interested in
    default_settings update_every: '5m'


    def on_load
        @day_checked = [0, 1, 2, 3, 4, 5, 6]
        @day_checking = [nil, nil, nil, nil, nil, nil, nil]

        on_update
    end

    def on_update
        self[:building] = setting(:building)
        self[:level] = setting(:level)
        self[:room] = setting(:room)

        self[:catering] = setting(:catering_system_id)
        if self[:catering]
            self[:menu] = setting(:menu)
        end

        # Load the last known values (persisted to the DB)
        self[:waiter_status] = (setting(:waiter_status) || :idle).to_sym
        self[:waiter_call] = self[:waiter_status] != :idle

        self[:catering_status] = setting(:last_catering_status) || {}
        self[:order_status] = :idle


        # unsubscribe to all swipe IDs if any are subscribed
        if @subs.present?
            @subs.each do |sub|
                unsubscribe(sub)
            end

            @subs = nil
        end

        # Are there any swipe card integrations
        if system.exists? :Security
            readers = setting(:card_readers)
            if readers.present?
                security = system[:Security]

                readers = readers.is_a?(Array) ? readers : [readers]
                sys = system
                @subs = []
                readers.each do |id|
                    @subs << sys.subscribe(:Security, 1, id.to_s) do |notice|
                        swipe_occured(notice.value)
                    end
                end
            end
        end

        fetch_bookings
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = schedule.every(setting(:fetch_bookings) || '5m', method(:fetch_bookings))
    end


    # ======================================
    # Waiter call information
    # ======================================
    def waiter_call(state)
        status = is_affirmative?(state)

        self[:waiter_call] = status

        # Used to highlight the service button
        if status
            self[:waiter_status] = :pending
        else
            self[:waiter_status] = :idle
        end

        define_setting(:waiter_status, self[:waiter_status])
    end

    def call_acknowledged
        self[:waiter_status] = :accepted
        define_setting(:waiter_status, self[:waiter_status])
    end


    # ======================================
    # Catering Management
    # ======================================
    def catering_status(details)
        self[:catering_status] = details

        # We'll turn off the green light on the waiter call button
        if self[:waiter_status] != :idle && status[:progress] == 'visited'
            self[:waiter_status] = :idle
            define_setting(:waiter_status, self[:waiter_status])
        end

        define_setting(:last_catering_status, details)
    end

    def commit_order(order_details)
        self[:order_status] = :pending
        status = self[:catering_status]

        if status && status[:progress] == 'visited'
            status = status.dup
            status[:progress] = 'cleaned'
            self[:catering_status] = status
        end

        if self[:catering]
            sys = system
            @oid ||= 1
            systems(self[:catering])[:Orders].add_order({
                id: "#{sys.id}_#{@oid}",
                created_at: Time.now.to_i,
                room_id: sys.id,
                room_name: sys.name,
                order: order_details
            })
        end
    end

    def order_accepted
        self[:order_status] = :accepted
    end

    def order_complete
        self[:order_status] = :idle
    end



    # ======================================
    # ROOM BOOKINGS:
    # ======================================
    def fetch_bookings(*args)
        # Fetches bookings from now to the end of the day
        findme = system[:FindMe]
        findme.meetings(self[:building], self[:level]).then do |raw|
            correct_level = true
            promises = []
            bookings = []

            raw.each do |value|
                correct_level = false if value[:ConferenceRoomAlias] !~ /#{self[:level]}/
                bookings << value if value[:ConferenceRoomAlias] == self[:room]
            end

            if !correct_level
                logger.warn "May have received the bookings for the wrong level\nExpecting #{self[:building]} level #{self[:level]} and received\n#{raw}"
            end

            if bookings.length > 0 || correct_level
                bookings.each do |booking|
                    username = booking[:BookingUserAlias]
                    if username
                        promise = findme.users_fullname(username)
                        promise.then do |name|
                            booking[:owner] = name
                        end
                        promises << promise
                    end
                end

                thread.all(*promises).then do
                    # UI will assume these are sorted
                    self[:today] = bookings
                end
            end
        end
    end

    def bookings_for(day)
        now = Time.now
        day_num = day.to_i
        current = now.wday

        if day_num != now.wday && @day_checked[day_num] < (now - 5.minutes)
            promise = @day_checking[day_num]
            return promise if promise

            # TODO:: Calculate the start and end times for this particular day

            # Clear the old data
            symbol = :"day_#{day_num}"
            self[symbol] = nil

            # We are looking for bookings on another day
            promise = system[:FindMe].meetings(self[:building], self[:level])
            @day_checking[day_num] = promise
            promise.then do |bookings|
                self[symbol] = bookings[self[:room]]
            end
            promise.finally do
                @day_checking[day_num] = nil
            end
        end
    end

    # TODO:: Provide a way to indicate if this succeeded or failed
    def schedule_meeting(user, starting, ending, subject)
        system[:FindMe].schedule_meeting(user, self[:room], starting, ending, subject)
    end


    # ======================================
    # Meeting Helper Functions
    # ======================================

    def start_meeting(meeting_ref, user_id = nil)

    end

    def cancel_meeting(meeting_ref, user_id = nil)

    end


    protected


    def swipe_occured(info)
        # Update the user details
        self[:fullname] = "#{info[:firstname]} #{info[:lastname]}"
        self[:username] = info[:staff_id]
    end
end
