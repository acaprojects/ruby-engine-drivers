# encoding: ASCII-8BIT
# frozen_string_literal: true

module HID
    module Algorithms
        class Wiegand
            attr_reader :wiegand
            attr_reader :facility
            attr_reader :card_number

            def initialize(wiegand, facility, card_number)
                @wiegand = wiegand
                @facility = facility
                @card_number = card_number
            end

            def self.count_1s(int)
                int.to_s(2).gsub('0', '').length
            end
        end

        class Wiegand26 < Wiegand
            FAC_PAR_MASK  = 0b11111111100000000000000000
            FACILITY_MASK = 0b01111111100000000000000000
            CARD_MASK     = 0b00000000011111111111111110
            CARD_PAR_MASK = 0b00000000011111111111111111

            # Convert wiegand 26 card data to components
            #
            # Hex card data: 0x21a6616
            # Card Number: 13067
            # Card Facility Code: 13
            def self.from_wiegand(card_data)
                card    = (card_data & CARD_MASK) >> 1
                card_1s = count_1s(card_data & CARD_PAR_MASK)

                facility    = (card_data & FACILITY_MASK) >> 17
                facility_1s = count_1s(card_data & FAC_PAR_MASK)

                parity_passed = card_1s.odd? && facility_1s.even?
                raise 'parity check error' unless parity_passed

                Wiegand26.new(card_data, facility, card)
            end

            # Convert components to wiegand 26 card data
            def self.from_components(facility, card)
                card_data = 0

                card_data += card << 1
                # Build the card parity bit (should be an odd number of ones)
                card_data += (FAC_PAR_MASK ^ FACILITY_MASK) if count_1s(card).odd?

                card_data += facility << 17
                # Build facility parity bit (should be an even number of ones)
                card_data += 1 if count_1s(facility).even?

                Wiegand26.new(card_data, facility, card)
            end
        end

        class Wiegand35 < Wiegand
            PAR_EVEN_MASK = 0b01101101101101101101101101101101100
            PAR_ODD_MASK  = 0b00110110110110110110110110110110110
            CARD_MASK     = 0b00000000000001111111111111111111100
            FACILITY_MASK = 0b01111111111110000000000000000000000

            # Outputs the HEX code of what is written to the swipe card
            #
            # Hex card data: 0x06F20107F
            # Card Number: 2540
            # Card Facility Code: 4033
            def from_components(facility, card)
                card_data = (facility << 22) + (card << 2)
                even_count = count_1s(card_data & PAR_EVEN_MASK)
                odd_count  = count_1s(card_data & PAR_ODD_MASK)

                # Even Parity
                card_data += (1 << 34) if even_count.odd?

                # Odd Parity
                card_data += 2 if odd_count.even?
                card_data = card_data.to_s(2).rjust(35, '0').reverse.to_i(2)

                Wiegand35.new(card_data, facility, card)
            end

            # Convert wiegand 35 card data to components
            #
            # 1 + 12 + 20 + 2
            # 1 + facility + card num + 2
            def self.from_wiegand(card_data)
                str = card_data.to_s(2).rjust(35, '0').reverse
                data = str.to_i(2)
                even_count = count_1s(data & PAR_EVEN_MASK) + (str[0] == '1' ? 1 : 0)
                odd_count  = count_1s(data & PAR_ODD_MASK)

                parity_passed = odd_count.odd? && even_count.even?
                raise 'parity check error' unless parity_passed

                facility = (data & FACILITY_MASK) >> 22
                card     = (data & CARD_MASK) >> 2
                Wiegand35.new(card_data, facility, card)
            end
        end
    end
end
