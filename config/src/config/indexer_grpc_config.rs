// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

use crate::config::{
    config_optimizer::ConfigOptimizer, node_config_loader::NodeType, Error, NodeConfig,
};
use aptos_types::chain_id::ChainId;
use serde::{Deserialize, Serialize};
use serde_yaml::Value;

// Useful indexer defaults
const DEFAULT_ADDRESS: &str = "0.0.0.0:50051";
const DEFAULT_OUTPUT_BATCH_SIZE: u16 = 100;
const DEFAULT_PROCESSOR_BATCH_SIZE: u16 = 1000;
const DEFAULT_PROCESSOR_TASK_COUNT: u16 = 20;

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct IndexerGrpcConfig {
    pub enabled: bool,

    /// The address that the grpc server will listen on
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub address: Option<String>,

    /// Number of processor tasks to fan out
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub processor_task_count: Option<u16>,

    /// Number of transactions each processor will process
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub processor_batch_size: Option<u16>,

    /// Number of transactions returned in a single stream response
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_batch_size: Option<u16>,
}

impl ConfigOptimizer for IndexerGrpcConfig {
    fn optimize(
        node_config: &mut NodeConfig,
        local_config_yaml: &Value,
        _node_type: NodeType,
        _chain_id: ChainId,
    ) -> Result<bool, Error> {
        let indexer_grpc_config = &mut node_config.indexer_grpc;
        let local_indexer_config_yaml = &local_config_yaml["indexer_grpc"];

        // If the indexer is not enabled, we don't need to do anything
        let mut modified_config = false;
        if !indexer_grpc_config.enabled {
            return Ok(modified_config);
        }

        // Set the address to the default if it is not set
        if local_indexer_config_yaml["address"].is_null() && indexer_grpc_config.address.is_none() {
            indexer_grpc_config.address = Some(DEFAULT_ADDRESS.into());
            modified_config = true;
        }

        // Set the processor task count to the default if it is not set
        if local_indexer_config_yaml["processor_task_count"].is_null()
            && indexer_grpc_config.processor_task_count.is_none()
        {
            indexer_grpc_config.processor_task_count = Some(DEFAULT_PROCESSOR_TASK_COUNT);
            modified_config = true;
        }

        // Set the processor batch size to the default if it is not set
        if local_indexer_config_yaml["processor_batch_size"].is_null()
            && indexer_grpc_config.processor_batch_size.is_none()
        {
            indexer_grpc_config.processor_batch_size = Some(DEFAULT_PROCESSOR_BATCH_SIZE);
            modified_config = true;
        }

        // Set the output batch size to the default if it is not set
        if local_indexer_config_yaml["output_batch_size"].is_null()
            && indexer_grpc_config.output_batch_size.is_none()
        {
            indexer_grpc_config.output_batch_size = Some(DEFAULT_OUTPUT_BATCH_SIZE);
            modified_config = true;
        }

        Ok(modified_config)
    }
}
