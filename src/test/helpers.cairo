use snforge_std::{EventSpy, EventSpyTrait, spy_events};
use starknet::ContractAddress;

#[derive(Drop)]
pub(crate) struct EventLogger {
    spy: EventSpy,
    index: usize,
}

pub(crate) fn event_logger() -> EventLogger {
    EventLogger { spy: spy_events(), index: 0 }
}

#[generate_trait]
pub(crate) impl EventLoggerImpl of EventLoggerTrait {
    fn pop_log<T, +starknet::Event<T>, +Drop<T>>(
        ref self: EventLogger, address: ContractAddress,
    ) -> Option<T> {
        let events = self.spy.get_events().events;
        loop {
            if self.index >= events.len() {
                break Option::None;
            }

            let (from, event) = events.at(self.index);
            self.index += 1;
            if *from == address {
                let mut keys = event.keys.span();
                let mut data = event.data.span();
                match starknet::Event::deserialize(ref keys, ref data) {
                    Option::Some(value) => { break Option::Some(value); },
                    Option::None => { continue; },
                }
            }
        }
    }
}
