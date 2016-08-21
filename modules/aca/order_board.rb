module Aca; end


class Aca::OrderBoard
    include ::Orchestrator::Constants


    descriptive_name 'Catering Dashboard'
    generic_name :Orders
    implements :logic

    
    # The rooms we are catering for
    default_settings rooms: [{
        name: "Room Name",
        sys_id: "sys-id"
    }]


    def on_load
        on_update
    end

    def on_update
        self[:name] = setting(:name) || system.name
        self[:rooms] = setting(:rooms)

        # Load any existing orders from the database
        self[:waiting] = setting(:current_waiting) || []
        self[:working] = setting(:current_working) || []
        self[:completed] = 0
    end

    def add_order(order)
        waiting = self[:waiting].dup
        waiting << order
        self[:waiting] = waiting
    end


    def progress(order_id)
        found = nil

        self[:waiting].each do |order|
            if order[:id] == order_id
                found = order
                break
            end
        end

        if found
            waiting = self[:waiting].dup
            working = self[:working].dup

            waiting.delete(found)
            found[:accepted_at] = Time.now.to_i
            working.push(found)

            self[:waiting] = waiting
            self[:working] = working

            systems(found[:room_id])[:Bookings].order_accepted
        else
            self[:working].each do |order|
                if order[:id] == order_id
                    found = order
                    break
                end
            end

            if found
                working = self[:working].dup
                working.delete(found)
                self[:working] = working
                self[:completed] += 1

                systems(found[:room_id])[:Bookings].order_complete
            end
        end

        define_setting(:current_waiting, self[:waiting])
        define_setting(:current_working, self[:working])
    end
end
