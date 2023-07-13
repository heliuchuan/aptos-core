// Copyright © Aptos Foundation

use crate::network_controller::{
    inbound_handler::InboundHandler, outbound_handler::OutboundHandler,
};
use crossbeam_channel::{unbounded, Receiver, Sender};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;

mod error;
mod inbound_handler;
mod outbound_handler;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[allow(dead_code)]
pub struct NetworkMessage {
    pub sender: SocketAddr,
    pub message: Message,
    pub message_type: MessageType,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, Hash, PartialEq)]
#[allow(dead_code)]
pub struct MessageType {
    message_type: String,
}

impl MessageType {
    pub fn new(message_type: String) -> Self {
        Self { message_type }
    }

    pub fn get_type(&self) -> String {
        self.message_type.clone()
    }
}

impl NetworkMessage {
    pub fn new(sender: SocketAddr, message: Message, message_type: MessageType) -> Self {
        Self {
            sender,
            message,
            message_type,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[allow(dead_code)]
pub struct Message {
    pub data: Vec<u8>,
}

impl Message {
    pub fn new(data: Vec<u8>) -> Self {
        Self { data }
    }

    pub fn to_bytes(self) -> Vec<u8> {
        self.data
    }
}

#[allow(dead_code)]
pub struct NetworkController {
    inbound_handler: InboundHandler,
    outbound_handler: OutboundHandler,
}

impl NetworkController {
    pub fn new(service: &'static str, listen_addr: SocketAddr, timeout_ms: u64) -> Self {
        Self {
            inbound_handler: InboundHandler::new(service, listen_addr, timeout_ms),
            outbound_handler: OutboundHandler::new(listen_addr),
        }
    }

    pub fn create_outbound_channel(
        &mut self,
        remote_peer_addr: SocketAddr,
        message_type: &'static str,
    ) -> Sender<Message> {
        let (outbound_sender, outbound_receiver) = unbounded();

        self.outbound_handler
            .register_handler(message_type, remote_peer_addr, outbound_receiver);

        outbound_sender
    }

    pub fn create_inbound_channel(&mut self, message_type: &'static str) -> Receiver<Message> {
        let (inbound_sender, inbound_receiver) = unbounded();

        self.inbound_handler
            .register_handler(message_type, inbound_sender);

        inbound_receiver
    }

    pub fn start(&mut self) {
        self.inbound_handler.start();
        self.outbound_handler.start();
    }
}

#[cfg(test)]
mod tests {
    use crate::network_controller::{Message, NetworkController};
    use aptos_config::utils;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};

    #[test]
    fn test_basic_send_receive() {
        let server_port1 = utils::get_available_port();
        let server_addr1 = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), server_port1);

        let server_port2 = utils::get_available_port();
        let server_addr2 = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), server_port2);

        let mut network_controller1 = NetworkController::new("test1", server_addr1, 1000);
        let mut network_controller2 = NetworkController::new("test2", server_addr2, 1000);

        let test1_sender = network_controller2.create_outbound_channel(server_addr1, "test1");
        let test1_receiver = network_controller1.create_inbound_channel("test1");

        let test2_sender = network_controller1.create_outbound_channel(server_addr2, "test2");
        let test2_receiver = network_controller2.create_inbound_channel("test2");

        network_controller1.start();
        network_controller2.start();

        let test1_message = "test1".as_bytes().to_vec();
        test1_sender
            .send(Message::new(test1_message.clone()))
            .unwrap();

        let test2_message = "test2".as_bytes().to_vec();
        test2_sender
            .send(Message::new(test2_message.clone()))
            .unwrap();

        let received_test1_message = test1_receiver.recv().unwrap();
        assert_eq!(received_test1_message.data, test1_message);

        let received_test2_message = test2_receiver.recv().unwrap();
        assert_eq!(received_test2_message.data, test2_message);
    }
}
