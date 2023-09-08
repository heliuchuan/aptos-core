// Copyright (c) The Diem Core Contributors
// Copyright (c) The Move Contributors
// SPDX-License-Identifier: Apache-2.0

//! This module defines the transfer functions for verifying consistency of each bytecode
//! instruction, in particular, for the bytecode instructions that come in both generic and
//! non-generic flavors. It also checks constraints on instructions like VecPack/VecUnpack.

use move_binary_format::{
    access::ModuleAccess,
    binary_views::BinaryIndexedView,
    errors::{Location, PartialVMError, PartialVMResult, VMResult},
    file_format::{
        Bytecode, CodeOffset, CodeUnit, CompiledModule, CompiledScript, FieldHandleIndex,
        FunctionDefinitionIndex, FunctionHandleIndex, FunctionInstantiation, StructDefinitionIndex,
        TableIndex, VirtualFunctionInstantiation,
    },
};
use move_core_types::vm_status::StatusCode;

pub struct InstructionConsistency<'a> {
    resolver: BinaryIndexedView<'a>,
    current_function: Option<FunctionDefinitionIndex>,
}

impl<'a> InstructionConsistency<'a> {
    pub fn verify_module(module: &'a CompiledModule) -> VMResult<()> {
        Self::verify_module_impl(module).map_err(|e| e.finish(Location::Module(module.self_id())))
    }

    fn verify_module_impl(module: &'a CompiledModule) -> PartialVMResult<()> {
        let resolver = BinaryIndexedView::Module(module);

        for (idx, func_def) in module.function_defs().iter().enumerate() {
            match &func_def.code {
                None => (),
                Some(code) => {
                    let checker = Self {
                        resolver,
                        current_function: Some(FunctionDefinitionIndex(idx as TableIndex)),
                    };
                    checker.check_instructions(code)?
                },
            }
        }
        for (idx, inst) in module.function_instantiations().iter().enumerate() {
            let checker = Self {
                resolver,
                current_function: Some(FunctionDefinitionIndex(idx as TableIndex)),
            };
            checker.check_function_instantiation(inst)?
        }
        Ok(())
    }

    pub fn verify_script(module: &'a CompiledScript) -> VMResult<()> {
        Self::verify_script_impl(module).map_err(|e| e.finish(Location::Script))
    }

    pub fn verify_script_impl(script: &'a CompiledScript) -> PartialVMResult<()> {
        let checker = Self {
            resolver: BinaryIndexedView::Script(script),
            current_function: None,
        };
        checker.check_instructions(&script.code)?;
        for inst in script.function_instantiations.iter() {
            checker.check_function_instantiation(inst)?;
        }
        Ok(())
    }

    fn check_function_instantiation(
        &self,
        func_inst: &FunctionInstantiation,
    ) -> PartialVMResult<()> {
        for func_inst in func_inst.vtable_instantiation.iter() {
            match func_inst {
                VirtualFunctionInstantiation::Defined(handle) => {
                    self.check_function_op(0, *handle, false)?
                },
                VirtualFunctionInstantiation::Instantiated(handle) => {
                    let inst = self.resolver.function_instantiation_at(*handle);
                    self.check_function_op(0, inst.handle, true)?
                },
                VirtualFunctionInstantiation::Inherited(_, _) => (),
            }
        }
        Ok(())
    }

    fn check_instructions(&self, code: &CodeUnit) -> PartialVMResult<()> {
        for (offset, instr) in code.code.iter().enumerate() {
            use Bytecode::*;

            match instr {
                MutBorrowField(field_handle_index) => {
                    self.check_field_op(offset, *field_handle_index, /* generic */ false)?;
                },
                MutBorrowFieldGeneric(field_inst_index) => {
                    let field_inst = self.resolver.field_instantiation_at(*field_inst_index)?;
                    self.check_field_op(offset, field_inst.handle, /* generic */ true)?;
                },
                ImmBorrowField(field_handle_index) => {
                    self.check_field_op(offset, *field_handle_index, /* generic */ false)?;
                },
                ImmBorrowFieldGeneric(field_inst_index) => {
                    let field_inst = self.resolver.field_instantiation_at(*field_inst_index)?;
                    self.check_field_op(offset, field_inst.handle, /* non_ */ true)?;
                },
                Call(idx) => {
                    self.check_function_op(offset, *idx, /* generic */ false)?;
                },
                CallGeneric(idx) => {
                    let func_inst = self.resolver.function_instantiation_at(*idx);
                    self.check_function_op(offset, func_inst.handle, /* generic */ true)?;
                },
                Pack(idx) => {
                    self.check_type_op(offset, *idx, /* generic */ false)?;
                },
                PackGeneric(idx) => {
                    let struct_inst = self.resolver.struct_instantiation_at(*idx)?;
                    self.check_type_op(offset, struct_inst.def, /* generic */ true)?;
                },
                Unpack(idx) => {
                    self.check_type_op(offset, *idx, /* generic */ false)?;
                },
                UnpackGeneric(idx) => {
                    let struct_inst = self.resolver.struct_instantiation_at(*idx)?;
                    self.check_type_op(offset, struct_inst.def, /* generic */ true)?;
                },
                MutBorrowGlobal(idx) => {
                    self.check_type_op(offset, *idx, /* generic */ false)?;
                },
                MutBorrowGlobalGeneric(idx) => {
                    let struct_inst = self.resolver.struct_instantiation_at(*idx)?;
                    self.check_type_op(offset, struct_inst.def, /* generic */ true)?;
                },
                ImmBorrowGlobal(idx) => {
                    self.check_type_op(offset, *idx, /* generic */ false)?;
                },
                ImmBorrowGlobalGeneric(idx) => {
                    let struct_inst = self.resolver.struct_instantiation_at(*idx)?;
                    self.check_type_op(offset, struct_inst.def, /* generic */ true)?;
                },
                Exists(idx) => {
                    self.check_type_op(offset, *idx, /* generic */ false)?;
                },
                ExistsGeneric(idx) => {
                    let struct_inst = self.resolver.struct_instantiation_at(*idx)?;
                    self.check_type_op(offset, struct_inst.def, /* generic */ true)?;
                },
                MoveFrom(idx) => {
                    self.check_type_op(offset, *idx, /* generic */ false)?;
                },
                MoveFromGeneric(idx) => {
                    let struct_inst = self.resolver.struct_instantiation_at(*idx)?;
                    self.check_type_op(offset, struct_inst.def, /* generic */ true)?;
                },
                MoveTo(idx) => {
                    self.check_type_op(offset, *idx, /* generic */ false)?;
                },
                MoveToGeneric(idx) => {
                    let struct_inst = self.resolver.struct_instantiation_at(*idx)?;
                    self.check_type_op(offset, struct_inst.def, /* generic */ true)?;
                },
                VecPack(_, num) | VecUnpack(_, num) => {
                    if *num > u16::MAX as u64 {
                        return Err(PartialVMError::new(StatusCode::CONSTRAINT_NOT_SATISFIED)
                            .at_code_offset(self.current_function(), offset as CodeOffset)
                            .with_message("VecPack/VecUnpack argument out of range".to_string()));
                    }
                },

                // List out the other options explicitly so there's a compile error if a new
                // bytecode gets added.
                FreezeRef | Pop | Ret | Branch(_) | BrTrue(_) | BrFalse(_) | LdU8(_) | LdU16(_)
                | LdU32(_) | LdU64(_) | LdU128(_) | LdU256(_) | LdConst(_) | CastU8 | CastU16
                | CastU32 | CastU64 | CastU128 | CastU256 | LdTrue | LdFalse | ReadRef
                | WriteRef | Add | Sub | Mul | Mod | Div | BitOr | BitAnd | Xor | Shl | Shr
                | Or | And | Not | Eq | Neq | Lt | Gt | Le | Ge | CopyLoc(_) | MoveLoc(_)
                | StLoc(_) | MutBorrowLoc(_) | ImmBorrowLoc(_) | VecLen(_) | VecImmBorrow(_)
                | VecMutBorrow(_) | VecPushBack(_) | VecPopBack(_) | VecSwap(_) | Abort | Nop
                | CallVirtual(_) => (),
            }
        }
        Ok(())
    }

    //
    // Helpers for instructions that come in a generic and non generic form.
    // Verifies the generic form uses a generic member and the non generic form
    // a non generic one.
    //

    fn check_field_op(
        &self,
        offset: usize,
        field_handle_index: FieldHandleIndex,
        generic: bool,
    ) -> PartialVMResult<()> {
        let field_handle = self.resolver.field_handle_at(field_handle_index)?;
        self.check_type_op(offset, field_handle.owner, generic)
    }

    fn current_function(&self) -> FunctionDefinitionIndex {
        self.current_function.unwrap_or(FunctionDefinitionIndex(0))
    }

    fn check_type_op(
        &self,
        offset: usize,
        struct_def_index: StructDefinitionIndex,
        generic: bool,
    ) -> PartialVMResult<()> {
        let struct_def = self.resolver.struct_def_at(struct_def_index)?;
        let struct_handle = self.resolver.struct_handle_at(struct_def.struct_handle);
        if struct_handle.type_parameters.is_empty() == generic {
            return Err(
                PartialVMError::new(StatusCode::GENERIC_MEMBER_OPCODE_MISMATCH)
                    .at_code_offset(self.current_function(), offset as CodeOffset),
            );
        }
        Ok(())
    }

    fn check_function_op(
        &self,
        offset: usize,
        func_handle_index: FunctionHandleIndex,
        generic: bool,
    ) -> PartialVMResult<()> {
        let function_handle = self.resolver.function_handle_at(func_handle_index);
        if function_handle.type_parameters.is_empty() == generic {
            return Err(
                PartialVMError::new(StatusCode::GENERIC_MEMBER_OPCODE_MISMATCH)
                    .at_code_offset(self.current_function(), offset as CodeOffset),
            );
        }
        Ok(())
    }
}
