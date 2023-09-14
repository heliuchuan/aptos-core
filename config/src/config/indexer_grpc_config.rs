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
        _local_config_yaml: &Value,
        _node_type: NodeType,
        _chain_id: ChainId,
    ) -> Result<bool, Error> {
        // If the indexer is not enabled, we don't need to do anything
        let indexer_grpc_config = &mut node_config.indexer_grpc;
        if !indexer_grpc_config.enabled {
            return Ok(false);
        }

        // TODO: we really shouldn't be overriding the configs if they are
        // specified in the local node config file. This optimizer should
        // migrate to the pattern used by other optimizers, but for now, we'll
        // just keep the legacy behaviour to avoid breaking anything.

        // Set appropriate defaults
        indexer_grpc_config.address = indexer_grpc_config
            .address
            .clone()
            .or_else(|| Some(DEFAULT_ADDRESS.into()));
        indexer_grpc_config.processor_task_count = indexer_grpc_config
            .processor_task_count
            .or(Some(DEFAULT_PROCESSOR_TASK_COUNT));
        indexer_grpc_config.processor_batch_size = indexer_grpc_config
            .processor_batch_size
            .or(Some(DEFAULT_PROCESSOR_BATCH_SIZE));
        indexer_grpc_config.output_batch_size = indexer_grpc_config
            .output_batch_size
            .or(Some(DEFAULT_OUTPUT_BATCH_SIZE));

        Ok(true)
    }
}
