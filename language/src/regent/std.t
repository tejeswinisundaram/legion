-- Copyright 2015 Stanford University, NVIDIA Corporation
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- Legion Standard Library

local config = require("regent/config")
local data = require("regent/data")
local log = require("regent/log")
local cudahelper

local std = {}

std.config, std.args = config.parse_args()

if std.config["cuda"] then cudahelper = require("regent/cudahelper") end

-- #####################################
-- ## Legion Bindings
-- #################

terralib.linklibrary("liblegion_terra.so")
local c = terralib.includecstring([[
#include "legion_c.h"
#include "legion_terra.h"
#include "legion_terra_partitions.h"
#include <stdio.h>
#include <stdlib.h>
]])
std.c = c

-- #####################################
-- ## Utilities
-- #################

terra std.assert(x : bool, message : rawstring)
  if not x then
    var stderr = c.fdopen(2, "w")
    c.fprintf(stderr, "assertion failed: %s\n", message)
    -- Just because it's stderr doesn't mean it's unbuffered...
    c.fflush(stderr)
    c.abort()
  end
end

terra std.domain_from_bounds_1d(start : c.legion_point_1d_t,
                                extent : c.legion_point_1d_t)
  var rect = c.legion_rect_1d_t {
    lo = start,
    hi = c.legion_point_1d_t {
      x = array(start.x[0] + extent.x[0] - 1),
    },
  }
  return c.legion_domain_from_rect_1d(rect)
end

terra std.domain_from_bounds_2d(start : c.legion_point_2d_t,
                                extent : c.legion_point_2d_t)
  var rect = c.legion_rect_2d_t {
    lo = start,
    hi = c.legion_point_2d_t {
      x = array(start.x[0] + extent.x[0] - 1,
                start.x[1] + extent.x[1] - 1),
    },
  }
  return c.legion_domain_from_rect_2d(rect)
end

terra std.domain_from_bounds_3d(start : c.legion_point_3d_t,
                                extent : c.legion_point_3d_t)
  var rect = c.legion_rect_3d_t {
    lo = start,
    hi = c.legion_point_3d_t {
      x = array(start.x[0] + extent.x[0] - 1,
                start.x[1] + extent.x[1] - 1,
                start.x[2] + extent.x[2] - 1),
    },
  }
  return c.legion_domain_from_rect_3d(rect)
end

-- #####################################
-- ## Privilege Helpers
-- #################

function std.add_privilege(cx, privilege, region, field_path)
  assert(type(privilege) == "string")
  assert(std.type_supports_privileges(region))
  assert(data.is_tuple(field_path))
  if not cx.privileges[privilege] then
    cx.privileges[privilege] = data.newmap()
  end
  if not cx.privileges[privilege][region] then
    cx.privileges[privilege][region] = data.newmap()
  end
  cx.privileges[privilege][region][field_path] = true
end

function std.copy_privileges(cx, from_region, to_region)
  assert(std.type_supports_privileges(from_region))
  assert(std.type_supports_privileges(to_region))
  local privileges_to_copy = terralib.newlist()
  for privilege, privilege_regions in cx.privileges:items() do
    local privilege_fields = privilege_regions[from_region]
    if privilege_fields then
      for _, field_path in privilege_fields:keys() do
        privileges_to_copy:insert({privilege, to_region, field_path})
      end
    end
  end
  for _, privilege in ipairs(privileges_to_copy) do
    std.add_privilege(cx, unpack(privilege))
  end
end

function std.add_constraint(cx, lhs, rhs, op, symmetric)
  assert(std.type_supports_constraints(lhs))
  assert(std.type_supports_constraints(rhs))
  if not cx.constraints[op] then
    cx.constraints[op] = {}
  end
  if not cx.constraints[op][lhs] then
    cx.constraints[op][lhs] = {}
  end
  cx.constraints[op][lhs][rhs] = true
  if symmetric then
    std.add_constraint(cx, rhs, lhs, op, false)
  end
end

function std.add_constraints(cx, constraints)
  for _, constraint in ipairs(constraints) do
    local lhs, rhs, op = constraint.lhs, constraint.rhs, constraint.op
    local symmetric = op == "*"
    std.add_constraint(cx, lhs.type, rhs.type, op, symmetric)
  end
end

function std.search_constraint_predicate(cx, region, visited, predicate)
  if predicate(cx, region) then
    return region
  end

  if visited[region] then
    return nil
  end
  visited[region] = true

  if cx.constraints["<="] and cx.constraints["<="][region] then
    for subregion, _ in pairs(cx.constraints["<="][region]) do
      local result = std.search_constraint_predicate(
        cx, subregion, visited, predicate)
      if result then return result end
    end
  end
  return nil
end

function std.search_privilege(cx, privilege, region, field_path, visited)
  assert(type(privilege) == "string")
  assert(std.type_supports_privileges(region))
  assert(data.is_tuple(field_path))
  return std.search_constraint_predicate(
    cx, region, visited,
    function(cx, region)
      return cx.privileges[privilege] and
        cx.privileges[privilege][region] and
        cx.privileges[privilege][region][field_path]
    end)
end

function std.check_privilege(cx, privilege, region, field_path)
  assert(type(privilege) == "string")
  assert(std.type_supports_privileges(region))
  assert(data.is_tuple(field_path))
  for i = #field_path, 0, -1 do
    if std.search_privilege(cx, privilege, region, field_path:slice(1, i), {}) then
      return true
    end
    if std.is_reduce(privilege) then
      if std.search_privilege(cx, std.reads, region, field_path:slice(1, i), {}) and
        std.search_privilege(cx, std.writes, region, field_path:slice(1, i), {})
      then
        return true
      end
    end
  end
  return false
end

function std.search_any_privilege(cx, region, field_path, visited)
  assert(std.is_region(region) and data.is_tuple(field_path))
  return std.search_constraint_predicate(
    cx, region, visited,
    function(cx, region)
      for _, regions in cx.privileges:items() do
        if regions[region] and regions[region][field_path] then
          return true
        end
      end
      return false
    end)
end

function std.check_any_privilege(cx, region, field_path)
  assert(std.is_region(region) and data.is_tuple(field_path))
  for i = #field_path, 0, -1 do
    if std.search_any_privilege(cx, region, field_path:slice(1, i), {}) then
      return true
    end
  end
  return false
end

function std.search_constraint(cx, region, constraint, visited, reflexive, symmetric)
  return std.search_constraint_predicate(
    cx, region, visited,
    function(cx, region)
      if reflexive and region == constraint.rhs then
        return true
      end

      if cx.constraints[constraint.op] and
        cx.constraints[constraint.op][region] and
        cx.constraints[constraint.op][region][constraint.rhs]
      then
        return true
      end

      if symmetric then
        local constraint = {
          lhs = constraint.rhs,
          rhs = region,
          op = constraint.op,
        }
        if std.search_constraint(cx, constraint.lhs, constraint, {}, reflexive, false) then
          return true
        end
      end

      return false
    end)
end

function std.check_constraint(cx, constraint)
  local lhs = constraint.lhs
  if lhs == wild then
    return true
  elseif terralib.issymbol(lhs) then
    lhs = lhs.type
  end
  assert(std.type_supports_constraints(lhs))

  local rhs = constraint.rhs
  if rhs == wild then
    return true
  elseif terralib.issymbol(rhs) then
    rhs = rhs.type
  end
  assert(std.type_supports_constraints(rhs))

  local constraint = {
    lhs = lhs,
    rhs = rhs,
    op = constraint.op,
  }
  return std.search_constraint(
    cx, constraint.lhs, constraint, {},
    constraint.op == "<=" --[[ reflexive ]],
    constraint.op == "*" --[[ symmetric ]])
end

function std.check_constraints(cx, constraints, mapping)
  if not mapping then
    mapping = {}
  end

  for _, constraint in ipairs(constraints) do
    local constraint = {
      lhs = mapping[constraint.lhs] or constraint.lhs,
      rhs = mapping[constraint.rhs] or constraint.rhs,
      op = constraint.op,
    }
    if not std.check_constraint(cx, constraint) then
      return false, constraint
    end
  end
  return true
end

function std.meet_privilege(a, b)
  if a == b then
    return a
  elseif not a then
    return b
  elseif not b then
    return a
  elseif a == "none" then
    return b
  elseif b == "none" then
    return a
  else
    return "reads_writes"
  end
end

function std.meet_coherence(a, b)
  if a == b then
    return a
  elseif not a then
    return b
  elseif not b then
    return a
  else
    assert(false)
  end
end

function std.meet_flag(a, b)
  if a == b then
    return a
  elseif not a or a == "no_flag" then
    return b
  elseif not b or b == "no_flag" then
    return a
  else
    assert(false)
  end
end

function std.is_reduction_op(privilege)
  return string.sub(privilege, 1, string.len("reduces ")) == "reduces "
end

function std.get_reduction_op(privilege)
  return string.sub(privilege, string.len("reduces ") + 1)
end

local function find_field_privilege(privileges, coherence_modes, flags,
                                    region_type, field_path, field_type)
  local field_privilege = "none"
  for _, privilege_list in ipairs(privileges) do
    for _, privilege in ipairs(privilege_list) do
      assert(terralib.issymbol(privilege.region))
      assert(data.is_tuple(privilege.field_path))
      if region_type == privilege.region.type and
        field_path:starts_with(privilege.field_path)
      then
        field_privilege = std.meet_privilege(field_privilege,
                                             privilege.privilege)
      end
    end
  end

  local coherence_mode = "exclusive"
  if coherence_modes[region_type] then
    for prefix, coherence in coherence_modes[region_type]:items() do
      if field_path:starts_with(prefix) then
        coherence_mode = coherence
      end
    end
  end

  local flag = "no_flag"
  if flags[region_type] then
    for prefix, flag_fields in flags[region_type]:items() do
      if field_path:starts_with(prefix) then
        for _, flag_kind in flag_fields:keys() do
          flag = std.meet_flag(flag, flag_kind)
        end
      end
    end
  end

  -- FIXME: Fow now, render write privileges as
  -- read-write. Otherwise, write would get rendered as
  -- write-discard, which would not be correct without explicit
  -- user annotation.
  if field_privilege == "writes" then
    field_privilege = "reads_writes"
  end

  if std.is_reduction_op(field_privilege) then
    local op = std.get_reduction_op(field_privilege)
    if not (std.reduction_op_ids[op] and std.reduction_op_ids[op][field_type]) then
      -- You could upgrade to reads_writes here, but this would never
      -- have made it past the parser anyway.
      assert(false)
    end
  end

  return field_privilege, coherence_mode, flag
end

function std.find_task_privileges(region_type, privileges, coherence_modes, flags)
  assert(std.type_supports_privileges(region_type))
  assert(privileges)
  assert(data.is_default_map(coherence_modes))
  assert(data.is_default_map(flags))
  local grouped_privileges = terralib.newlist()
  local grouped_coherence_modes = terralib.newlist()
  local grouped_flags = terralib.newlist()
  local grouped_field_paths = terralib.newlist()
  local grouped_field_types = terralib.newlist()

  local field_paths, field_types = std.flatten_struct_fields(
    region_type:fspace())

  local privilege_index = data.newmap()
  local privilege_next_index = 1
  for i, field_path in ipairs(field_paths) do
    local field_type = field_types[i]
    local privilege, coherence, flag = find_field_privilege(
      privileges, coherence_modes, flags, region_type, field_path, field_type)
    local mode = data.newtuple(privilege, coherence, flag)
    if privilege ~= "none" then
      local index = privilege_index[mode]
      if not index then
        index = privilege_next_index
        privilege_next_index = privilege_next_index + 1

        -- Reduction privileges cannot be grouped, because the Legion
        -- runtime does not know how to handle multi-field reductions.
        if not std.is_reduction_op(privilege) then
          privilege_index[mode] = index
        end

        grouped_privileges:insert(privilege)
        grouped_coherence_modes:insert(coherence)
        grouped_flags:insert(flag)
        grouped_field_paths:insert(terralib.newlist())
        grouped_field_types:insert(terralib.newlist())
      end

      grouped_field_paths[index]:insert(field_path)
      grouped_field_types[index]:insert(field_type)
    end
  end

  if #grouped_privileges == 0 then
    grouped_privileges:insert("none")
    grouped_coherence_modes:insert("exclusive")
    grouped_flags:insert("no_flag")
    grouped_field_paths:insert(terralib.newlist())
    grouped_field_types:insert(terralib.newlist())
  end

  return grouped_privileges, grouped_field_paths, grouped_field_types,
    grouped_coherence_modes, grouped_flags
end

function std.group_task_privileges_by_field_path(privileges, privilege_field_paths)
  local privileges_by_field_path = {}
  for i, privilege in ipairs(privileges) do
    local field_paths = privilege_field_paths[i]
    for _, field_path in ipairs(field_paths) do
      privileges_by_field_path[field_path:hash()] = privilege
    end
  end
  return privileges_by_field_path
end

local privilege_modes = {
  none            = c.NO_ACCESS,
  reads           = c.READ_ONLY,
  writes          = c.WRITE_ONLY,
  reads_writes    = c.READ_WRITE,
}

function std.privilege_mode(privilege)
  local mode = privilege_modes[privilege]
  if std.is_reduction_op(privilege) then
    mode = c.REDUCE
  end
  assert(mode)
  return mode
end

local coherence_modes = {
  exclusive       = c.EXCLUSIVE,
  atomic          = c.ATOMIC,
  simultaneous    = c.SIMULTANEOUS,
  relaxed         = c.RELAXED,
}

function std.coherence_mode(coherence)
  local mode = coherence_modes[coherence]
  assert(mode)
  return mode
end

local flag_modes = {
  no_flag         = c.NO_FLAG,
  verified_flag   = c.VERIFIED_FLAG,
  no_access_flag  = c.NO_ACCESS_FLAG,
}

function std.flag_mode(flag)
  local mode = flag_modes[flag]
  assert(mode)
  return mode
end

-- #####################################
-- ## Type Helpers
-- #################

function std.is_bounded_type(t)
  return terralib.types.istype(t) and rawget(t, "is_bounded_type")
end

function std.is_index_type(t)
  return terralib.types.istype(t) and rawget(t, "is_index_type")
end

function std.is_ispace(t)
  return terralib.types.istype(t) and rawget(t, "is_ispace")
end

function std.is_region(t)
  return terralib.types.istype(t) and rawget(t, "is_region")
end

function std.is_partition(t)
  return terralib.types.istype(t) and rawget(t, "is_partition")
end

function std.is_cross_product(t)
  return terralib.types.istype(t) and rawget(t, "is_cross_product")
end

function std.is_vptr(t)
  return terralib.types.istype(t) and rawget(t, "is_vpointer")
end

function std.is_sov(t)
  return terralib.types.istype(t) and rawget(t, "is_struct_of_vectors")
end

function std.is_ref(t)
  return terralib.types.istype(t) and rawget(t, "is_ref")
end

function std.is_rawref(t)
  return terralib.types.istype(t) and rawget(t, "is_rawref")
end

function std.is_future(t)
  return terralib.types.istype(t) and rawget(t, "is_future")
end

function std.is_list(t)
  return terralib.types.istype(t) and rawget(t, "is_list")
end

function std.is_list_of_regions(t)
  return std.is_list(t) and t:is_list_of_regions()
end

function std.is_list_of_phase_barriers(t)
  return std.is_list(t) and t:is_list_of_phase_barriers()
end

function std.is_phase_barrier(t)
  return terralib.types.istype(t) and rawget(t, "is_phase_barrier")
end

function std.is_unpack_result(t)
  return terralib.types.istype(t) and rawget(t, "is_unpack_result")
end

function std.type_supports_privileges(t)
  return std.is_region(t) or std.is_list_of_regions(t)
end

function std.type_supports_constraints(t)
  return std.is_region(t) or std.is_partition(t) or
    std.is_list_of_regions(t)
end

function std.is_fspace(x)
  return getmetatable(x) == fspace
end

function std.is_fspace_instance(t)
  return terralib.types.istype(t) and rawget(t, "is_fspace_instance")
end

struct std.untyped {}

function std.type_sub(t, mapping)
  if mapping[t] then
    return mapping[t]
  elseif std.is_bounded_type(t) then
    if t.points_to_type then
      return t.index_type(
        std.type_sub(t.points_to_type, mapping),
        unpack(t.bounds_symbols:map(
                 function(bound) return std.type_sub(bound, mapping) end)))
    else
      return t.index_type(
        unpack(t.bounds_symbols:map(
                 function(bound) return std.type_sub(bound, mapping) end)))
    end
  elseif std.is_fspace_instance(t) then
    return t.fspace(unpack(t.args:map(
      function(arg) return std.type_sub(arg, mapping) end)))
  elseif std.is_rawref(t) then
    return std.rawref(std.type_sub(t.pointer_type, mapping))
  elseif std.is_ref(t) then
    return std.ref(std.type_sub(t.pointer_type, mapping), unpack(t.field_path))
  elseif terralib.types.istype(t) and t:ispointer() then
    return &std.type_sub(t.type, mapping)
  else
    return t
  end
end

function std.type_eq(a, b, mapping)
  -- Determine if a == b with substitutions mapping a -> b

  if not mapping then
    mapping = {}
  end

  if a == b then
    return true
  elseif mapping[a] == b then
    return true
  elseif terralib.issymbol(a) and terralib.issymbol(b) then
    if a == wild or b == wild then
      return true
    end
    return std.type_eq(a.type, b.type, mapping)
  elseif std.is_bounded_type(a) and std.is_bounded_type(b) then
    if not std.type_eq(a.points_to_type, b.points_to_type, mapping) then
      return false
    end
    local a_bounds = a:bounds()
    local b_bounds = b:bounds()
    if #a_bounds ~= #b_bounds then
      return false
    end
    for i, a_region in ipairs(a_bounds) do
      local b_region = b_bounds[i]
      if not std.type_eq(a_region, b_region, mapping) then
        return false
      end
    end
    return true
  elseif std.is_fspace_instance(a) and std.is_fspace_instance(b) and
    a.fspace == b.fspace
  then
    for i, a_arg in ipairs(a.args) do
      local b_arg = b.args[i]
      if not std.type_eq(a_arg, b_arg, mapping) then
        return false
      end
    end
    return true
  elseif std.is_list(a) and std.is_list(b) then
    return std.type_eq(a.element_type, b.element_type, mapping)
  else
    return false
  end
end

function std.type_maybe_eq(a, b, mapping)
  -- Returns false ONLY if a and b are provably DIFFERENT types. So
  --
  --     type_maybe_eq(ptr(int, a), ptr(int, b))
  --
  -- might return true (even if a and b are NOT type_eq) because if
  -- the regions a and b alias then it is possible for a value to
  -- inhabit both types.

  if std.type_eq(a, b, mapping) then
    return true
  elseif std.is_bounded_type(a) and std.is_bounded_type(b) then
    return std.type_maybe_eq(a.points_to_type, b.points_to_type, mapping)
  elseif std.is_fspace_instance(a) and std.is_fspace_instance(b) and
    a.fspace == b.fspace
  then
    return true
  elseif std.is_list(a) and std.is_list(b) then
    return std.type_maybe_eq(a.element_type, b.element_type, mapping)
  else
    return false
  end
end

function std.type_meet(a, b)
  local function test()
    local terra query(x : a, y : b)
      if true then return x end
      if true then return y end
    end
    return query:gettype().returntype
  end
  local valid, result_type = pcall(test)

  if valid then
    return result_type
  end
end

local function add_region_symbol(symbols, region)
  assert(region.type)
  if not symbols[region.type] then
    symbols[region.type] = region
  end
end

local function add_type(symbols, type)
  if std.is_bounded_type(type) then
    for _, bound in ipairs(type.bounds_symbols) do
      add_region_symbol(symbols, bound)
    end
  elseif std.is_fspace_instance(type) then
    for _, arg in ipairs(type.args) do
      add_region_symbol(symbols, arg)
    end
  elseif std.is_list(type) then
    add_type(symbols, type.element_type)
  elseif std.is_region(type) then
    -- FIXME: Would prefer to not get errors at all here.
    pcall(function() add_type(symbols, type.fspace_type) end)
  end
end

function std.struct_entries_symbols(fs, symbols)
  if not symbols then
    symbols = {}
  end
  fs:getentries():map(function(entry)
      add_type(symbols, entry[2] or entry.type)
  end)
  if std.is_fspace_instance(fs) then
    fs:getconstraints():map(function(constraint)
      add_region_symbol(symbols, constraint.lhs)
      add_region_symbol(symbols, constraint.rhs)
    end)
  end

  local entries_symbols = terralib.newlist()
  for _, entry in ipairs(fs:getentries()) do
    local field_name = entry[1] or entry.field
    local field_type = entry[2] or entry.type
    if terralib.issymbol(field_name) then
      entries_symbols:insert(field_name)
    elseif symbols[field_type] then
      entries_symbols:insert(symbols[field_type])
    else
      local new_symbol = terralib.newsymbol(field_type, field_name)
      entries_symbols:insert(new_symbol)
    end
  end

  return entries_symbols
end

function std.fn_param_symbols(fn_type)
  local params = fn_type.parameters
  local symbols = {}
  params:map(function(param) add_type(symbols, param) end)
  add_type(symbols, fn_type.returntype)

  local param_symbols = terralib.newlist()
  for _, param in ipairs(params) do
    if symbols[param] then
      param_symbols:insert(symbols[param])
    else
      param_symbols:insert(terralib.newsymbol(param))
    end
  end

  return param_symbols
end

local function type_compatible(a, b)
  return (std.is_ispace(a) and std.is_ispace(b)) or
    (std.is_region(a) and std.is_region(b)) or
    (std.is_partition(a) and std.is_partition(b)) or
    (std.is_cross_product(a) and std.is_cross_product(b)) or
    (std.is_list_of_regions(a) and std.is_list_of_regions(b))
end

local function type_isomorphic(param_type, arg_type, check, mapping)
  if std.is_ispace(param_type) and std.is_ispace(arg_type) then
    return std.type_eq(param_type.index_type, arg_type.index_type, mapping)
  elseif std.is_region(param_type) and std.is_region(arg_type) then
      return std.type_eq(param_type.fspace_type, arg_type.fspace_type, mapping)
  elseif std.is_partition(param_type) and std.is_partition(arg_type) then
    return (param_type:is_disjoint() == arg_type:is_disjoint()) and
      (check(param_type:parent_region(), arg_type:parent_region(), mapping))
  elseif
    std.is_cross_product(param_type) and std.is_cross_product(arg_type)
  then
    return (#param_type:partitions() == #arg_type:partitions()) and
      data.all(
        unpack(data.zip(param_type:partitions(), arg_type:partitions()):map(
          function(pair)
            local param_partition, arg_partition = unpack(pair)
            return check(param_partition, arg_partition, mapping)
      end)))
  elseif std.is_list_of_regions(param_type) and std.is_list_of_regions(arg_type)
  then
    return std.type_eq(
      param_type.element_type:fspace(), arg_type.element_type:fspace())
  else
    return false
  end
end

local function reconstruct_param_as_arg_type(param_type, mapping)
  if std.is_ispace(param_type) then
    local index_type = std.type_sub(param_type.index_type, mapping)
    return std.ispace(index_type)
  elseif std.is_region(param_type) then
    local fspace_type = std.type_sub(param_type.fspace_type, mapping)
    return std.region(fspace_type)
  elseif std.is_partition(param_type) then
    local param_parent_region = param_type:parent_region()
    local param_parent_region_as_arg_type = mapping[param_parent_region]
    for k, v in pairs(mapping) do
      if terralib.issymbol(v) and v.type == mapping[param_parent_region] then
        param_parent_region_as_arg_type = v
      end
    end
    return std.partition(
      param_type.disjointness, param_parent_region_as_arg_type)
  elseif std.is_cross_product(param_type) then
    local param_partitions = param_type:partitions()
    local param_partitions_as_arg_type = param_partitions:map(
      function(param_partition)
        local param_partition_as_arg_type = mapping[param_partition]
        for k, v in pairs(mapping) do
          if terralib.issymbol(v) and v.type == mapping[param_partition] then
            param_partition_as_arg_type = v
          end
        end
        return param_partition_as_arg_type
    end)
    return std.cross_product(unpack(param_partitions_as_arg_type))
  elseif std.is_list_of_regions(param_type) then
    local fspace_type = std.type_sub(param_type.element_type.fspace_type, mapping)
    return std.list(std.region(fspace_type))
  else
    assert(false)
  end
end

function std.validate_args(node, params, args, isvararg, return_type, mapping, strict)
  if (#args < #params) or (#args > #params and not isvararg) then
    log.error(node, "expected " .. tostring(#params) .. " arguments but got " .. tostring(#args))
  end

  -- FIXME: All of these calls are being done with the order backwards
  -- for validate_implicit_cast, but everything breaks if I swap the
  -- order. For the moment, the fix is to make validate_implicit_cast
  -- symmetric as much as possible.
  local check
  if strict then
    check = std.type_eq
  else
    check = std.validate_implicit_cast
  end

  if not mapping then
    mapping = {}
  end

  for i, param in ipairs(params) do
    local arg = args[i]
    local param_type = param.type
    local arg_type = arg.type

    -- Sanity check that we're not getting references here.
    assert(not (std.is_ref(arg_type) or std.is_rawref(arg_type)))

    if param_type == std.untyped or
      param_type == arg_type or
      mapping[param_type] == arg_type
    then
      -- Ok
    elseif type_compatible(param_type, arg_type) then
      -- Regions (and other unique types) require a special pass here 

      -- Check for previous mappings. This can happen if two
      -- parameters are aliased to the same region.
      if (mapping[param] or mapping[param_type]) and
        not (mapping[param] == arg or mapping[param_type] == arg_type)
      then
        local param_as_arg_type = mapping[param_type]
        for k, v in pairs(mapping) do
          if terralib.issymbol(v) and v.type == mapping[param_type] then
            param_as_arg_type = v
          end
        end
        log.error(node, "type mismatch in argument " .. tostring(i) ..
                    ": expected " .. tostring(param_as_arg_type) ..
                    " but got " .. tostring(arg))
      end

      mapping[param] = arg
      mapping[param_type] = arg_type
      if not type_isomorphic(param_type, arg_type, check, mapping) then
        local param_as_arg_type = reconstruct_param_as_arg_type(param_type, mapping)
        log.error(node, "type mismatch in argument " .. tostring(i) ..
                    ": expected " .. tostring(param_as_arg_type) ..
                    " but got " .. tostring(arg_type))
      end
    elseif not check(param_type, arg_type, mapping) then
      local param_as_arg_type = std.type_sub(param_type, mapping)
      log.error(node, "type mismatch in argument " .. tostring(i) ..
                  ": expected " .. tostring(param_as_arg_type) ..
                  " but got " .. tostring(arg_type))
    end
  end
  return std.type_sub(return_type, mapping)
end

function std.validate_fields(fields, constraints, params, args)
  local mapping = {}
  for i, param in ipairs(params) do
    local arg = args[i]
    mapping[param] = arg
  end

  local new_fields = terralib.newlist()
  for _, old_field in ipairs(fields) do
    local old_symbol, old_type = old_field.field, old_field.type
    local new_symbol = terralib.newsymbol(old_symbol.displayname)
    local new_type
    if std.is_region(old_type) then
      mapping[old_symbol] = new_symbol
      local new_fspace_type = std.type_sub(old_type.fspace_type, mapping)
      new_type = std.region(new_fspace_type)
    else
      new_type = std.type_sub(old_type, mapping)
    end
    new_symbol.type = new_type
    new_fields:insert({
        field = new_symbol.displayname,
        type = new_type,
    })
  end

  local new_constraints = terralib.newlist()
  for _, constraint in ipairs(constraints) do
    local lhs = mapping[constraint.lhs] or constraint.lhs
    local rhs = mapping[constraint.rhs] or constraint.rhs
    local op = constraint.op
    assert(lhs and rhs and op)
    new_constraints:insert({
        lhs = lhs,
        rhs = rhs,
        op = op,
    })
  end

  return new_fields, new_constraints
end

-- Terra differentiates between implicit and explicit
-- casting. Therefore, if you explicitly cast here then e.g. bool ->
-- int appears valid, but if you implicitly cast, this is invalid. For
-- now, use implicit casts. Unfortunately, for compatibility with
-- Terra, we need both behaviors.

function std.validate_implicit_cast(from_type, to_type, mapping)
  if std.type_eq(from_type, to_type, mapping) then
    return true
  end

  -- Ask the Terra compiler to kindly tell us the cast is valid.
  local function test()
    local terra query(x : from_type) : to_type
      return x
    end
    return query:gettype().returntype
  end
  local valid = pcall(test)

  return valid
end

function std.validate_explicit_cast(from_type, to_type, mapping)
  if std.type_eq(from_type, to_type, mapping) then
    return true
  end

  -- Ask the Terra compiler to kindly tell us the cast is valid.
  local function test()
    local terra query(x : from_type) : to_type
      return [to_type](x)
    end
    return query:gettype().returntype
  end
  local valid = pcall(test)

  return valid
end

function std.unpack_fields(fs, symbols)
  assert(std.is_fspace_instance(fs))

  fs:complete() -- Need fields
  local old_symbols = std.struct_entries_symbols(fs)

  local mapping = {}
  local new_fields = terralib.newlist()
  for i, old_field in ipairs(fs:getentries()) do
    local old_symbol, old_type = old_symbols[i], old_field.type
    local new_symbol
    local field_name = old_field[1] or old_field.field
    if symbols and symbols[field_name] then
      new_symbol = symbols[field_name]
    else
      new_symbol = terralib.newsymbol(old_symbol.displayname)
    end
    local new_type
    if std.is_region(old_type) then
      mapping[old_symbol] = new_symbol
      local fspace_type = std.type_sub(old_type.fspace_type, mapping)
      new_type = std.region(fspace_type)
    else
      new_type = std.type_sub(old_type, mapping)
    end
    new_symbol.type = new_type
    new_fields:insert({
        field = new_symbol.displayname,
        type = new_type,
    })
  end

  local constraints = fs:getconstraints()
  local new_constraints = terralib.newlist()
  for _, constraint in ipairs(constraints) do
    local lhs = mapping[constraint.lhs] or constraint.lhs
    local rhs = mapping[constraint.rhs] or constraint.rhs
    local op = constraint.op
    new_constraints:insert({
        lhs = lhs,
        rhs = rhs,
        op = op,
    })
  end

  local result_type = terralib.types.newstruct()
  result_type.is_unpack_result = true
  result_type.entries = new_fields

  return result_type, new_constraints
end

function std.as_read(t)
  assert(terralib.types.istype(t))
  if std.is_ref(t) then
    local field_type = t.refers_to_type
    for _, field in ipairs(t.field_path) do
      field_type = std.get_field(field_type, field)
      if not field_type then
        return nil
      end
    end
    assert(not std.is_ref(field_type))
    return field_type
  elseif std.is_rawref(t) then
    return t.refers_to_type
  else
    return t
  end
end

function std.check_read(cx, node)
  local t = node.expr_type
  assert(terralib.types.istype(t))
  if std.is_ref(t) then
    local region_types, field_path = t:bounds(), t.field_path
    for i, region_type in ipairs(region_types) do
      if not std.check_privilege(cx, std.reads, region_type, field_path) then
        local regions = t.bounds_symbols
        local ref_as_ptr = t.pointer_type.index_type(t.refers_to_type, unpack(regions))
        log.error(node, "invalid privilege reads(" ..
                  (data.newtuple(regions[i]) .. field_path):mkstring(".") ..
                  ") for dereference of " .. tostring(ref_as_ptr))
      end
    end
  end
  return std.as_read(t)
end

function std.check_write(cx, node)
  local t = node.expr_type
  assert(terralib.types.istype(t))
  if std.is_ref(t) then
    local region_types, field_path = t:bounds(), t.field_path
    for i, region_type in ipairs(region_types) do
      if not std.check_privilege(cx, std.writes, region_type, field_path) then
        local regions = t.bounds_symbols
        local ref_as_ptr = t.pointer_type.index_type(t.refers_to_type, unpack(regions))
        log.error(node, "invalid privilege writes(" ..
                  (data.newtuple(regions[i]) .. field_path):mkstring(".") ..
                  ") for dereference of " .. tostring(ref_as_ptr))
      end
    end
    return std.as_read(t)
  elseif std.is_rawref(t) then
    return std.as_read(t)
  else
    log.error(node, "type mismatch: write expected an lvalue but got " .. tostring(t))
  end
end

function std.check_reduce(cx, op, node)
  local t = node.expr_type
  assert(terralib.types.istype(t))
  if std.is_ref(t) then
    local region_types, field_path = t:bounds(), t.field_path
    for i, region_type in ipairs(region_types) do
      if not std.check_privilege(cx, std.reduces(op), region_type, field_path) then
        local regions = t.bounds_symbols
        local ref_as_ptr = t.pointer_type.index_type(t.refers_to_type, unpack(regions))
        log.error(node, "invalid privilege " .. tostring(std.reduces(op)) .. "(" ..
                  (data.newtuple(regions[i]) .. field_path):mkstring(".") ..
                  ") for dereference of " .. tostring(ref_as_ptr))
      end
    end
    return std.as_read(t)
  elseif std.is_rawref(t) then
    return std.as_read(t)
  else
    log.error(node, "type mismatch: reduce expected an lvalue but got " .. tostring(t))
  end
end

function std.get_field(t, f)
  assert(terralib.types.istype(t))
  if std.is_bounded_type(t) then
    if not t:is_ptr() then
      return nil
    end
    local field_type = std.ref(t, f)
    if not std.as_read(field_type) then
      return nil
    end
    return field_type
  elseif std.is_ref(t) then
    local field_path = terralib.newlist()
    for _, field in ipairs(t.field_path) do
      field_path:insert(field)
    end
    field_path:insert(f)
    local field_type = std.ref(t, unpack(field_path))
    if not std.as_read(field_type) then
      return nil
    end
    return field_type
  elseif std.is_rawref(t) then
    local field_type = std.get_field(std.as_read(t), f)
    if std.is_ref(field_type) then
      return field_type
    elseif field_type then
      return std.rawref(&field_type)
    else
      return nil
    end
  else
    -- Ask the Terra compiler to kindly tell us the type of the requested field.
    local function test()
      local terra query(x : t)
        return x.[f]
      end
      return query:gettype().returntype
    end
    local exists, field_type = pcall(test)
    if exists then
      return field_type
    else
      return nil
    end
  end
end

function std.get_field_path(value_type, field_path)
  for _, field_name in ipairs(field_path) do
    value_type = std.get_field(value_type, field_name)
  end
  return value_type
end

function std.implicit_cast(from, to, expr)
   assert(not (std.is_ref(from) or std.is_rawref(from)))
   if std.is_ispace(to) or std.is_region(to) or std.is_partition(to) or
     std.is_cross_product(to) or std.is_list_of_regions(to) or
     std.is_bounded_type(to) or std.is_fspace_instance(to)
  then
    return to:force_cast(from, to, expr)
  elseif std.is_index_type(to) then
    return `([to](expr))
  else
    return quote var v : to = [expr] in v end
  end
end

function std.explicit_cast(from, to, expr)
   if std.is_ispace(to) or std.is_region(to) or std.is_partition(to) or
     std.is_cross_product(to) or std.is_list_of_regions(to) or
     std.is_bounded_type(to) or std.is_fspace_instance(to)
   then
    return to:force_cast(from, to, expr)
  else
    return `([to](expr))
  end
end

function std.flatten_struct_fields(struct_type)
  assert(terralib.types.istype(struct_type))
  local field_paths = terralib.newlist()
  local field_types = terralib.newlist()
  if struct_type:isstruct() or std.is_fspace_instance(struct_type) then
    local entries = struct_type:getentries()
    for _, entry in ipairs(entries) do
      local entry_name = entry[1] or entry.field
      -- FIXME: Fix for struct types with symbol fields.
      assert(type(entry_name) == "string")
      local entry_type = entry[2] or entry.type
      local entry_field_paths, entry_field_types =
        std.flatten_struct_fields(entry_type)
      field_paths:insertall(
        entry_field_paths:map(
          function(entry_field_path)
            return data.newtuple(entry_name) .. entry_field_path
          end))
      field_types:insertall(entry_field_types)
    end
  else
    field_paths:insert(data.newtuple())
    field_types:insert(struct_type)
  end

  return field_paths, field_types
end

function std.fn_params_with_privileges_by_index(fn_type)
  local params = fn_type.parameters
  return data.filteri(std.type_supports_privileges, params)
end

function std.fn_param_regions_by_index(fn_type)
  local params = fn_type.parameters
  return data.filteri(std.is_region, params)
end

function std.fn_param_lists_of_regions_by_index(fn_type)
  local params = fn_type.parameters
  return data.filteri(function(t) return std.is_list_of_regions(t) end, params)
end

-- #####################################
-- ## Serialization Helpers
-- #################

function std.compute_serialized_size(value_type, value)
  if std.is_list(value_type) then
    local result = terralib.newsymbol(c.size_t, "result")
    local element_type = value_type.element_type
    local element = terralib.newsymbol(&element_type)

    local size_actions, size_value = std.compute_serialized_size(
      element_type, element)
    local actions = quote
      var [result] = 0
      for i = 0, [value].__size do
        var [element] = ([&element_type]([value].__data)) + i
        [size_actions]
        [result] = [result] + terralib.sizeof(element_type) + [size_value]
      end
    end
    return actions, result
  else
    return quote end, 0
  end
end

function std.serialize(value_type, value, fixed_ptr, data_ptr)
  -- Force unaligned access because malloc does not provide
  -- blocks aligned for all purposes (e.g. SSE vectors).
  local value_type_alignment = 1 -- data.min(terralib.sizeof(value_type), 8)
  local actions = quote
    terralib.attrstore(
      [&value_type](fixed_ptr), value,
      { align = [value_type_alignment] })
  end

  if std.is_list(value_type) then
    local element_type = value_type.element_type
    local element = terralib.newsymbol(element_type)
    local element_ptr = terralib.newsymbol(&element_type)

    local ser_actions = std.serialize(
      element_type, element, element_ptr, data_ptr)
    actions = quote
      [actions]
      for i = 0, [value].__size do
        var [element] = ([&element_type]([value].__data))[i]
        var [element_ptr] = [&element_type](@[data_ptr])
        @[data_ptr] = @[data_ptr] + terralib.sizeof(element_type)
        [ser_actions]
      end
    end
  end

  return actions
end

function std.deserialize(value_type, fixed_ptr, data_ptr)
  -- Force unaligned access because malloc does not provide
  -- blocks aligned for all purposes (e.g. SSE vectors).
  local value_type_alignment = 1 -- data.min(terralib.sizeof(value_type), 8)
  local result = terralib.newsymbol(value_type, "result")
  local actions = quote
    var [result] = terralib.attrload(
      [&value_type]([fixed_ptr]),
      { align = [value_type_alignment] })
  end

  if std.is_list(value_type) then
    local element_type = value_type.element_type
    local element_ptr = terralib.newsymbol(&element_type)

    local deser_actions, deser_value = std.deserialize(
      element_type, element_ptr, data_ptr)
    actions = quote
      [actions]
      [result].__data = c.malloc(
        terralib.sizeof(element_type) * [result].__size)
      std.assert([result].__data ~= nil, "malloc failed in deserialize")
      for i = 0, [result].__size do
        var [element_ptr] = [&element_type](@[data_ptr])
        @[data_ptr] = @[data_ptr] + terralib.sizeof(element_type)
        [deser_actions]
        ([&element_type]([result].__data))[i] = [deser_value]
      end
    end
  end

  return actions, result
end

-- Keep in sync with std.type_size_bucket_type
function std.type_size_bucket_name(value_type)
  if std.is_list(value_type) then
    return ""
  elseif value_type == terralib.types.unit then
    return "_void"
  elseif terralib.sizeof(value_type) == 4 then
    return "_uint32"
  elseif terralib.sizeof(value_type) == 8 then
    return "_uint64"
  else
    return ""
  end
end

-- Keep in sync with std.type_size_bucket_name
function std.type_size_bucket_type(value_type)
  if std.is_list(value_type) then
    return c.legion_task_result_t
  elseif value_type == terralib.types.unit then
    return terralib.types.unit
  elseif terralib.sizeof(value_type) == 4 then
    return uint32
  elseif terralib.sizeof(value_type) == 8 then
    return uint64
  else
    return c.legion_task_result_t
  end
end

-- #####################################
-- ## Types
-- #################

-- WARNING: Bounded types are NOT unique. If two regions are aliased
-- then it is possible for two different pointer types to be equal:
--
-- var r = region(ispace(ptr, n), t)
-- var s = r
-- var x = new(ptr(t, r))
-- var y = new(ptr(t, s))
--
-- The types of x and y are distinct objects, but are still type_eq.
local bounded_type = terralib.memoize(function(index_type, ...)
  assert(std.is_index_type(index_type))
  local bounds = terralib.newlist({...})
  local points_to_type = false
  if #bounds > 0 then
    if terralib.types.istype(bounds[1]) then
      points_to_type = bounds[1]
      bounds:remove(1)
    end
  end
  if #bounds <= 0 then
    error(tostring(index_type) .. " expected at least one ispace or region, got none")
  end
  for i, bound in ipairs(bounds) do
    if not terralib.issymbol(bound) then
      local offset = 0
      if points_to_type then
        offset = offset + 1
      end
      error(tostring(index_type) .. " expected a symbol as argument " ..
              tostring(i+offset) .. ", got " .. tostring(bound))
    end
  end

  local st = terralib.types.newstruct(tostring(index_type))
  st.entries = terralib.newlist({
      { "__ptr", index_type.impl_type },
  })
  if #bounds > 1 then
    -- Find the smallest bitmask that will fit.
    -- TODO: Would be nice to compress smaller than one byte.
   local bitmask_type
    if #bounds < bit.lshift(1, 8) - 1 then
      bitmask_type = uint8
    elseif #bounds < bit.lshift(1, 16) - 1 then
      bitmask_type = uint16
    elseif #bounds < bit.lshift(1, 32) - 1 then
      bitmask_type = uint32
    else
      assert(false) -- really?
    end
    st.entries:insert({ "__index", bitmask_type })
  end

  st.is_bounded_type = true
  st.index_type = index_type
  st.points_to_type = points_to_type
  st.bounds_symbols = bounds
  st.dim = index_type.dim
  st.fields = index_type.fields

  function st:is_ptr()
    return self.points_to_type ~= false
  end

  function st:bounds()
    local bounds = terralib.newlist()
    local is_ispace = false
    local is_region = false
    for i, bound_symbol in ipairs(self.bounds_symbols) do
      local bound = bound_symbol.type
      if terralib.types.istype(bound) then
        bound = std.as_read(bound)
      end
      if not (terralib.types.istype(bound) and
              (std.is_ispace(bound) or std.is_region(bound)))
      then
        log.error(nil, tostring(self.index_type) ..
                    " expected an ispace or region as argument " ..
                    tostring(i+1) .. ", got " .. tostring(bound))
      end
      if std.is_region(bound) and
        not (std.type_eq(bound.fspace_type, self.points_to_type) or
             (self.points_to_type:isvector() and
              std.type_eq(bound.fspace_type, self.points_to_type.type)) or
             std.is_unpack_result(self.points_to_type))
      then
        log.error(nil, tostring(self.index_type) .. " expected region(" ..
                    tostring(self.points_to_type) .. ") as argument " ..
                    tostring(i+1) .. ", got " .. tostring(bound))
      end
      if std.is_ispace(bound) then is_ispace = true end
      if std.is_region(bound) then is_region = true end
      bounds:insert(bound)
    end
    if is_ispace and is_region then
      log.error(nil, tostring(self.index_type) .. " bounds may not mix ispaces and regions")
    end
    return bounds
  end

  st.metamethods.__eq = macro(function(a, b)
      assert(std.is_bounded_type(a:gettype()) and std.is_bounded_type(b:gettype()))
      assert(a.index_type == b.index_type)
      return `(a.__ptr.value == b.__ptr.value)
  end)

  st.metamethods.__ne = macro(function(a, b)
      assert(std.is_bounded_type(a:gettype()) and std.is_bounded_type(b:gettype()))
      assert(a.index_type == b.index_type)
      return `(a.__ptr.value ~= b.__ptr.value)
  end)

  function st.metamethods.__cast(from, to, expr)
    if std.is_bounded_type(from) then
      if std.validate_implicit_cast(from.index_type, to) then
        return `([to]([from.index_type]({ __ptr = [expr].__ptr })))
      end
    end
    assert(false)
  end

  terra st.metamethods.__add(a : st.index_type, b : st.index_type) : st.index_type
    return st { __ptr = a.__ptr + b.__ptr }
  end

  function st:force_cast(from, to, expr)
    assert(std.is_bounded_type(from) and std.is_bounded_type(to) and
             (#(from:bounds()) > 1) == (#(to:bounds()) > 1))
    if #(to:bounds()) == 1 then
      return `([to]{ __ptr = [expr].__ptr })
    else
      return quote var x = [expr] in [to]{ __ptr = x.__ptr, __index = x.__index} end
    end
  end

  function st.metamethods.__typename(st)
    local bounds = st.bounds_symbols

    if st.points_to_type then
      return tostring(st.index_type) .. "(" .. tostring(st.points_to_type) .. ", " .. tostring(bounds:mkstring(", ")) .. ")"
    else
      return tostring(st.index_type) .. "(" .. tostring(bounds:mkstring(", ")) .. ")"
    end
  end

  return st
end)

local function validate_index_base_type(base_type)
  assert(terralib.types.istype(base_type),
         "Index type expected a type, got " .. tostring(base_type))
  if std.type_eq(base_type, opaque) then
    return c.legion_ptr_t, 0, terralib.newlist({"value"})
  elseif std.type_eq(base_type, int) then
    return base_type, 1, false
  elseif base_type:isstruct() then
    local entries = base_type:getentries()
    assert(#entries >= 1 and #entries <= 3,
           "Multi-dimensional index type expected 1 to 3 fields, got " ..
             tostring(#entries))
    for _, entry in ipairs(entries) do
      local field_type = entry[2] or entry.type
      assert(std.type_eq(field_type, int),
             "Multi-dimensional index type expected fields to be " .. tostring(int) ..
               ", got " .. tostring(field_type))
    end
    return base_type, #entries, entries:map(function(entry) return entry[1] or entry.field end)
  else
    assert(false, "Index type expected " .. tostring(opaque) .. ", " ..
             tostring(int) .. " or a struct, got " .. tostring(base_type))
  end
end

-- Hack: Terra uses getmetatable() in terralib.types.istype(), so
-- setting a custom metatable on a type requires some trickery. The
-- approach used here is to define __metatable() to return the
-- expected type metatable so that the object is recongized as a type.

local index_type = {}
for k, v in pairs(getmetatable(int)) do
  index_type[k] = v
end
index_type.__call = bounded_type
index_type.__metatable = getmetatable(int)

function std.index_type(base_type, displayname)
  local impl_type, dim, fields = validate_index_base_type(base_type)

  local st = terralib.types.newstruct(displayname)
  st.entries = terralib.newlist({
      { "__ptr", impl_type },
  })

  st.is_index_type = true
  st.base_type = base_type
  st.impl_type = impl_type
  st.dim = dim
  st.fields = fields

  function st:is_opaque()
    return std.type_eq(self.base_type, opaque)
  end

  function st.metamethods.__cast(from, to, expr)
    if std.is_index_type(to) then
      if to:is_opaque() and std.validate_implicit_cast(from, int) then
        return `([to]{ __ptr = c.legion_ptr_t { value = [expr] } })
      elseif not to:is_opaque() and std.validate_implicit_cast(from, to.base_type) then
        return `([to]{ __ptr = [expr] })
      end
    elseif std.is_index_type(from) then
      if from:is_opaque() and std.validate_implicit_cast(int, to) then
        return `([to]([expr].__ptr.value))
      elseif not from:is_opaque() and std.validate_implicit_cast(from.base_type, to) then
        return `([to]([expr].__ptr))
      end
    end
    assert(false)
  end

  terra st.metamethods.__add(a : st, b : st) : st
    return st { __ptr = a.__ptr + b.__ptr }
  end

  function st:zero()
    assert(self.dim >= 1)
    local fields = self.fields
    local pt = c["legion_point_" .. tostring(self.dim) .. "d_t"]

    if fields then
      return `(self { __ptr = [self.impl_type] { [fields:map(function(_) return 0 end)] } })
    else
      return `(self({ __ptr = [self.impl_type](0) }))
    end
  end

  function st:to_point(expr)
    assert(self.dim >= 1)
    local fields = self.fields
    local pt = c["legion_point_" .. tostring(self.dim) .. "d_t"]

    if fields then
      return quote
        var v = [expr].__ptr
      in
        pt { x = arrayof(int, [fields:map(function(field) return `(v.[field]) end)]) }
      end
    else
      return quote var v = [expr].__ptr in pt { x = arrayof(int, v) } end
    end
  end

  return setmetatable(st, index_type)
end

local struct int2d { x : int, y : int }
local struct int3d { x : int, y : int, z : int }
std.ptr = std.index_type(opaque, "ptr")
std.int1d = std.index_type(int, "int1d")
std.int2d = std.index_type(int2d, "int2d")
std.int3d = std.index_type(int3d, "int3d")

function std.ispace(index_type)
  assert(terralib.types.istype(index_type) and std.is_index_type(index_type),
         "Ispace type requires index type")

  local st = terralib.types.newstruct("ispace")
  st.entries = terralib.newlist({
      { "impl", c.legion_index_space_t },
  })

  st.is_ispace = true
  st.index_type = index_type
  st.dim = index_type.dim

  -- Ispace types can have an optional partition. This is used by
  -- cross_product to enable patterns like prod[i][j]. Of course, the
  -- ispace can have other partitions as well. This is simply used as
  -- the default partition when attempting to access something out of
  -- a ispace.
  function st:set_default_partition(partition)
    local previous_default = rawget(self, "partition")
    if previous_default and previous_default ~= partition then
      assert(false, "Ispace type can only have one default partition")
    end
    if not (std.is_partition(partition) or std.is_cross_product(partition)) then
      assert(false, "Ispace type requires default partition to be a partition or cross product")
    end
    if partition:parent_ispace() ~= self then
      assert(false, "Ispace type requires default partition to be a partition of self")
    end
    self.partition = partition
  end

  function st:has_default_partition()
    return rawget(self, "partition")
  end

  function st:default_partition()
    local partition = rawget(self, "partition")
    if not partition then
      assert(false, "Ispace type has no default partition")
    end
    return partition
  end

  -- Methods for the partition API:
  function st:is_disjoint()
    return self:default_partition():is_disjoint()
  end

  function st:parent_ispace()
    return self
  end

  function st:subispace_constant(i)
    return self:default_partition():subispace_constant(i)
  end

  function st:subispaces_constant()
    return self:default_partition():subispaces_constant()
  end

  function st:subispace_dynamic(i)
    return self:default_partition():subispace_dynamic(i)
  end

  function st:force_cast(from, to, expr)
    assert(std.is_ispace(from) and std.is_ispace(to))
    return `([to] { impl = [expr].impl })
  end

  function st.metamethods.__typename(st)
    return "ispace(" .. tostring(st.index_type) .. ")"
  end

  return st
end

function std.region(ispace_symbol, fspace_type)
  if fspace_type == nil then
    fspace_type = ispace_symbol
    ispace_symbol = terralib.newsymbol(std.ispace(std.ptr))
  end

  assert(terralib.issymbol(ispace_symbol),
         "Region type requires ispace")
  assert(terralib.types.istype(fspace_type),
         "Region type requires fspace type")
  assert(not std.is_list_of_regions(fspace_type),
         "Region type requires fspace type to not be a list type")

  local st = terralib.types.newstruct("region")
  st.entries = terralib.newlist({
      { "impl", c.legion_logical_region_t },
  })

  st.is_region = true
  st.ispace_symbol = ispace_symbol
  st.fspace_type = fspace_type

  function st:ispace()
    local ispace = self.ispace_symbol.type
    assert(terralib.types.istype(ispace) and
             std.is_ispace(ispace),
           "Parition type requires ispace")
    return ispace
  end

  function st:fspace()
    return st.fspace_type
  end

  -- For API compatibility with std.list:
  function st:list_depth()
    return 0
  end

  -- Region types can have an optional partition. This is used by
  -- cross_product to enable patterns like prod[i][j]. Of course, the
  -- region can have other partitions as well. This is simply used as
  -- the default partition when attempting to access something out of
  -- a region.
  function st:set_default_partition(partition)
    local previous_default = rawget(self, "partition")
    if previous_default and previous_default ~= partition then
      assert(false, "Region type can only have one default partition")
    end
    if not std.is_partition(partition) then
      assert(false, "Region type requires default partition to be a partition")
    end
    if partition:parent_region() ~= self then
      assert(false, "Region type requires default partition to be a partition of self")
    end
    self.partition = partition
  end

  function st:has_default_partition()
    return rawget(self, "partition")
  end

  function st:default_partition()
    local partition = rawget(self, "partition")
    if not partition then
      assert(false, "Region type has no default partition")
    end
    return partition
  end

  function st:set_default_product(product)
    local previous_default = rawget(self, "product")
    if previous_default and previous_default ~= product then
      assert(false, "Region type can only have one default product")
    end
    if not std.is_cross_product(product) then
      assert(false, "Region type requires default product to be a cross product")
    end
    if product:parent_region() ~= self then
      assert(false, "Region type requires default product to be a partition of self")
    end
    self.product = product
  end

  function st:has_default_product()
    return rawget(self, "product")
  end

  function st:default_product()
    local product = rawget(self, "product")
    if not product then
      assert(false, "Region type has no default product")
    end
    return product
  end

  -- Methods for the partition API:
  function st:is_disjoint()
    return self:default_partition():is_disjoint()
  end

  function st:parent_region()
    return self
  end

  function st:subregion_constant(i)
    return self:default_partition():subregion_constant(i)
  end

  function st:subregions_constant()
    return self:default_partition():subregions_constant()
  end

  function st:subregion_dynamic(i)
    return self:default_partition():subregion_dynamic(i)
  end

  function st:force_cast(from, to, expr)
    assert(std.is_region(from) and std.is_region(to))
    return `([to] { impl = [expr].impl })
  end

  function st:hash()
    return self
  end

  function st.metamethods.__typename(st)
    return "region(" .. tostring(st.fspace_type) .. ")"
  end

  return st
end

std.wild = terralib.newsymbol("wild")

std.disjoint = terralib.types.newstruct("disjoint")
std.aliased = terralib.types.newstruct("aliased")

function std.partition(disjointness, region)
  assert(disjointness == std.disjoint or disjointness == std.aliased,
         "Partition type requires disjointness to be one of disjoint or aliased")
  assert(terralib.issymbol(region),
         "Partition type requires region to be a symbol")
  if terralib.types.istype(region.type) then
    assert(std.is_region(region.type),
           "Parition type requires region")
  end

  local st = terralib.types.newstruct("partition")
  st.entries = terralib.newlist({
      { "impl", c.legion_logical_partition_t },
  })

  st.is_partition = true
  st.disjointness = disjointness
  st.parent_region_symbol = region
  st.subregions = {}

  function st:is_disjoint()
    return self.disjointness == std.disjoint
  end

  function st:partition()
    return self
  end

  function st:parent_region()
    local region = self.parent_region_symbol.type
    assert(terralib.types.istype(region) and
             std.is_region(region),
           "Parition type requires region")
    return region
  end

  function st:fspace()
    return self:parent_region():fspace()
  end

  function st:subregions_constant()
    return self.subregions
  end

  function st:subregion_constant(i)
    assert(type(i) == "number" or terralib.issymbol(i))
    if not self.subregions[i] then
      self.subregions[i] = std.region(self:parent_region().fspace_type)
    end
    return self.subregions[i]
  end

  function st:subregion_dynamic()
    return std.region(self:parent_region().fspace_type)
  end

  function st:force_cast(from, to, expr)
    assert(std.is_partition(from) and std.is_partition(to))
    return `([to] { impl = [expr].impl })
  end

  function st:hash()
    return self
  end

  function st.metamethods.__typename(st)
    return "partition(" .. tostring(st.disjointness) .. ", " .. tostring(st.parent_region_symbol) .. ")"
  end

  return st
end

function std.cross_product(...)
  local partition_symbols = terralib.newlist({...})
  assert(#partition_symbols >= 2, "Cross product type requires at least 2 arguments")
  for i, partition_symbol in ipairs(partition_symbols) do
    assert(terralib.issymbol(partition_symbol),
           "Cross product type requires argument " .. tostring(i) .. " to be a symbol")
    if terralib.types.istype(partition_symbol.type) then
      assert(std.is_partition(partition_symbol.type),
             "Cross prodcut type requires argument " .. tostring(i) .. " to be a partition")
    end
  end

  local st = terralib.types.newstruct("cross_product")
  st.entries = terralib.newlist({
      { "impl", c.legion_logical_partition_t },
      { "product", c.legion_terra_index_cross_product_t },
      { "partitions", c.legion_index_partition_t[#partition_symbols] },
  })

  st.is_cross_product = true
  st.partition_symbols = partition_symbols
  st.subpartitions = {}

  function st:partitions()
    return self.partition_symbols:map(
      function(partition_symbol)
        local partition = partition_symbol.type
        assert(terralib.types.istype(partition) and
                 std.is_partition(partition),
               "Cross product type requires partition")
        return partition
    end)
  end

  function st:partition(i)
    return self:partitions()[i or 1]
  end

  function st:is_disjoint()
    return self:partition():is_disjoint()
  end

  function st:parent_region()
    return self:partition():parent_region()
  end

  function st:subregion_constant(i)
    local region_type = self:partition():subregion_constant(i)
    local partition_type = self:subpartition_constant(i, region_type)
    if std.is_cross_product(partition_type) then
      region_type:set_default_partition(partition_type:partition())
      region_type:set_default_product(partition_type)
    elseif std.is_partition(partition_type) then
      region_type:set_default_partition(partition_type)
    else
      assert(false)
    end
    return region_type
  end

  function st:subregions_constant()
    return self:partition():subregions_constant()
  end

  function st:subregion_dynamic(i)
    local region_type = self:partition():subregion_dynamic(i)
    local partition_type = self:subpartition_dynamic(i, region_type)
    if std.is_cross_product(partition_type) then
      region_type:set_default_partition(partition_type:partition())
      region_type:set_default_product(partition_type)
    elseif std.is_partition(partition_type) then
      region_type:set_default_partition(partition_type)
    else
      assert(false)
    end
    return region_type
  end

  function st:subpartition_constant(i, region_type)
    if not self.subpartitions[i] then
      local partition = st:subpartition_dynamic(i, region_type)
      self.subpartitions[i] = partition
    end
    return self.subpartitions[i]
  end

  function st:subpartition_dynamic(i, region_type)
    local region_symbol = terralib.newsymbol(region_type)
    local partition = std.partition(self:partition(2).disjointness, region_symbol)
    if #partition_symbols > 2 then
      local partition_symbol = terralib.newsymbol(partition)
      local subpartition_symbols = terralib.newlist({partition_symbol})
      for i = 3, #partition_symbols do
        subpartition_symbols:insert(partition_symbols[i])
      end
      return std.cross_product(unpack(subpartition_symbols))
    else
      return partition
    end
  end

  function st:force_cast(from, to, expr)
    assert(std.is_cross_product(from) and std.is_cross_product(to))
    -- FIXME: Potential for double (triple) evaluation here.
    return `([to] { impl = [expr].impl, product = [expr].product, partitions = [expr].partitions })
  end

  function st:hash()
    return self
  end

  function st.metamethods.__typename(st)
    return "cross_product(" .. st.partition_symbols:mkstring(", ") .. ")"
  end

  return st
end

std.vptr = terralib.memoize(function(width, points_to_type, ...)
  local bounds = terralib.newlist({...})

  local vec = vector(uint32, width)
  local struct legion_vptr_t {
    value : vec
  }
  local st = terralib.types.newstruct("vptr")
  st.entries = terralib.newlist({
      { "__ptr", legion_vptr_t },
  })

  local bitmask_type
  if #bounds > 1 then
    -- Find the smallest bitmask that will fit.
    -- TODO: Would be nice to compress smaller than one byte.
    if #bounds < bit.lshift(1, 8) - 1 then
      bitmask_type = vector(uint8, width)
    elseif #bounds < bit.lshift(1, 16) - 1 then
      bitmask_type = vector(uint16, width)
    elseif #bounds < bit.lshift(1, 32) - 1 then
      bitmask_type = vector(uint32, width)
    else
      assert(false) -- really?
    end
    st.entries:insert({ "__index", bitmask_type })
  end

  st.is_vpointer = true
  st.points_to_type = points_to_type
  st.bounds_symbols = bounds
  st.N = width
  st.type = ptr(points_to_type, ...)

  function st:bounds()
    local bounds = terralib.newlist()
    for i, region_symbol in ipairs(self.bounds_symbols) do
      local region = region_symbol.type
      if not (terralib.types.istype(region) and std.is_region(region)) then
        log.error(nil, "vptr expected a region as argument " .. tostring(i+1) ..
                    ", got " .. tostring(region.type))
      end
      if not std.type_eq(region.fspace_type, points_to_type) then
        log.error(nil, "vptr expected region(" .. tostring(points_to_type) ..
                    ") as argument " .. tostring(i+1) ..
                    ", got " .. tostring(region))
      end
      bounds:insert(region)
    end
    return bounds
  end

  function st.metamethods.__typename(st)
    local bounds = st.bounds_symbols

    return "vptr(" .. st.N .. ", " ..
           tostring(st.points_to_type) .. ", " ..
           tostring(bounds:mkstring(", ")) .. ")"
  end

  return st
end)

std.sov = terralib.memoize(function(struct_type, width)
  -- Sanity check that referee type is not a ref.
  assert(not std.is_ref(struct_type))
  assert(not std.is_rawref(struct_type))

  local st = terralib.types.newstruct("sov")
  st.entries = terralib.newlist()
  for _, entry in pairs(struct_type:getentries()) do
    local entry_field = entry[1] or entry.field
    local entry_type = entry[2] or entry.type
    if entry_type:isprimitive() then
      st.entries:insert{entry_field, vector(entry_type, width)}
    else
      st.entries:insert{entry_field, std.sov(entry_type, width)}
    end
  end
  st.is_struct_of_vectors = true
  st.type = struct_type
  st.N = width

  function st.metamethods.__typename(st)
    return "sov(" .. tostring(st.type) .. ", " .. tostring(st.N) .. ")"
  end

  return st
end)

-- The ref type is a reference to a ptr type. Note that ref is
-- different from ptr in that it is not intended to be used by code;
-- it exists mainly to facilitate field-sensitive privilege checks in
-- the type system.
std.ref = terralib.memoize(function(pointer_type, ...)
  if not terralib.types.istype(pointer_type) then
    error("ref expected a type as argument 1, got " .. tostring(pointer_type))
  end
  if not (std.is_bounded_type(pointer_type) or std.is_ref(pointer_type)) then
    error("ref expected a bounded type or ref as argument 1, got " .. tostring(pointer_type))
  end
  if std.is_ref(pointer_type) then
    pointer_type = pointer_type.pointer_type
  end

  local st = terralib.types.newstruct("ref")

  st.is_ref = true
  st.pointer_type = pointer_type
  st.refers_to_type = pointer_type.points_to_type
  st.bounds_symbols = pointer_type.bounds_symbols
  st.field_path = data.newtuple(...)

  function st:bounds()
    return self.pointer_type:bounds()
  end

  function st.metamethods.__typename(st)
    local bounds = st.bounds_symbols

    return "ref(" .. tostring(st.refers_to_type) .. ", " .. tostring(bounds:mkstring(", ")) .. ")"
  end

  return st
end)

std.rawref = terralib.memoize(function(pointer_type)
  if not terralib.types.istype(pointer_type) then
    error("rawref expected a type as argument 1, got " .. tostring(pointer_type))
  end
  if not pointer_type:ispointer() then
    error("rawref expected a pointer type as argument 1, got " .. tostring(pointer_type))
  end
  -- Sanity check that referee type is not a ref.
  assert(not std.is_ref(pointer_type.type))

  local st = terralib.types.newstruct("rawref")

  st.is_rawref = true
  st.pointer_type = pointer_type
  st.refers_to_type = pointer_type.type

  function st.metamethods.__typename(st)
    return "rawref(" .. tostring(st.refers_to_type) .. ")"
  end

  return st
end)

std.future = terralib.memoize(function(result_type)
  if not terralib.types.istype(result_type) then
    error("future expected a type as argument 1, got " .. tostring(result_type))
  end
  assert(not std.is_rawref(result_type))

  local st = terralib.types.newstruct("future")
  st.entries = terralib.newlist({
      { "__result", c.legion_future_t },
  })

  st.is_future = true
  st.result_type = result_type

  function st.metamethods.__typename(st)
    return "future(" .. tostring(st.result_type) .. ")"
  end

  return st
end)

std.list = terralib.memoize(function(element_type, partition_type, privilege_depth)
  if not terralib.types.istype(element_type) then
    error("list expected a type as argument 1, got " .. tostring(element_type))
  end

  if partition_type and not std.is_partition(partition_type) then
    error("list expected a partition type as argument 2, got " .. tostring(partition_type))
  end

  local st = terralib.types.newstruct("list")
  st.entries = terralib.newlist({
      { "__size", uint64 }, -- in elements
      { "__data", &opaque },
  })
  if partition_type then
    st.entries:insert({ "__partition", c.legion_logical_partition_t })
  end

  st.is_list = true
  st.element_type = element_type
  st.partition_type = partition_type or false
  st.privilege_depth = privilege_depth or 0

  function st:is_list_of_regions()
    return std.is_region(self.element_type) or
      std.is_list_of_regions(self.element_type)
  end

  function st:is_list_of_phase_barriers()
    return std.is_phase_barrier(self.element_type) or
      std.is_list_of_phase_barriers(self.element_type)
  end

  function st:partition()
    return self.partition_type
  end

  function st:list_depth()
    if std.is_list(self.element_type) then
      return 1 + self.element_type:list_depth()
    else
      return 1
    end
  end

  function st:leaf_element_type()
    if std.is_list(self.element_type) then
      return self.element_type:leaf_element_type()
    end
    return self.element_type
  end

  function st:region()
    assert(std.is_list_of_regions(self))
    if std.is_list(self.element_type) then
      return self.element_type:region()
    end
    return self.element_type
  end

  function st:ispace()
    assert(std.is_list_of_regions(self))
    return self.element_type:ispace()
  end

  function st:fspace()
    assert(std.is_list_of_regions(self))
    return self.element_type:fspace()
  end

  function st:subregion_dynamic()
    assert(std.is_list_of_regions(self))
    local ispace = terralib.newsymbol(
      std.ispace(self:ispace().index_type),
      self:region().ispace_symbol.displayname)
    return std.region(ispace, self:fspace())
  end

  function st:slice(strip_levels)
    if strip_levels == nil then strip_levels = 0 end
    assert(std.is_list_of_regions(self))
    local slice_type = self:subregion_dynamic()
    for i = 1 + strip_levels, self:list_depth() do
      slice_type = std.list(
        slice_type, self:partition(), self.privilege_depth)
    end
    return slice_type
  end

  -- FIXME: Make the compiler manage cleanups, including lists.

  function st:data(value)
    return `([&self.element_type]([value].__data))
  end

  function st:hash()
    return self
  end

  function st:force_cast(from, to, expr)
    assert(std.is_list_of_regions(from) and std.is_list_of_regions(to))
    -- FIXME: This would result in memory corruption if we ever freed
    -- the original data.
    if to:partition() then
      assert(from:partition())
      return `([to] {
          __size = [expr].__size,
          __data = [expr].__data,
          __partition = [expr].__partition,
        })
    else
      return `([to] { __size = [expr].__size, __data = [expr].__data })
    end
  end

  function st.metamethods.__typename(st)
    return "list(" .. tostring(st.element_type) .. ")"
  end

  return st
end)

do
  local st = terralib.types.newstruct("phase_barrier")
  std.phase_barrier = st
  st.entries = terralib.newlist({
      { "impl", c.legion_phase_barrier_t },
  })

  st.is_phase_barrier = true

  -- For API compatibility with std.list:
  function st:list_depth()
    return 0
  end
end

do
  local function field_name(field)
    local field_name = field["field"] or field[1]
    if terralib.issymbol(field_name) then
      return field_name.displayname
    else
      return field_name
    end
  end

  local function field_type(field)
    return field["type"] or field[2]
  end

  function std.ctor(fields)
    local st = terralib.types.newstruct()
    st.entries = fields
    st.metamethods.__cast = function(from, to, expr)
      if std.is_index_type(to) then
        return `([to]{ __ptr = [to.impl_type](expr)})
      elseif to:isstruct() then
        local from_fields = {}
        for _, from_field in ipairs(to:getentries()) do
          from_fields[field_name(from_field)] = field_type(from_field)
        end
        local mapping = terralib.newlist()
        for _, to_field in ipairs(to:getentries()) do
          local to_field_name = field_name(to_field)
          local to_field_type = field_type(to_field)
          local from_field_type = from_fields[to_field_name]
          if not (from_field_type and to_field_type == from_field_type) then
            error()
          end
          mapping:insert({from_field_type, to_field_type, to_field_name})
        end

        local v = terralib.newsymbol()
        local fields = mapping:map(
          function(field_mapping)
            local from_field_type, to_field_type, to_field_name = unpack(
              field_mapping)
            return std.implicit_cast(
              from_field_type, to_field_type, `([v].[to_field_name]))
          end)

        return quote var [v] = [expr] in [to]({ [fields] }) end
      else
        error("ctor must cast to a struct")
      end
    end
    return st
  end
end

-- #####################################
-- ## Privileges
-- #################

std.reads = "reads"
std.writes = "writes"
function std.reduces(op)
  local ops = {
    ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true,
    ["max"] = true, ["min"] = true,
  }
  assert(ops[op])
  return "reduces " .. tostring(op)
end

function std.is_reduce(privilege)
  local base = "reduces "
  return string.sub(privilege, 1, string.len(base)) == base
end

function std.privilege(privilege, regions_fields)
  local privileges = terralib.newlist()
  for _, region_fields in ipairs(regions_fields) do
    local region, fields
    if terralib.issymbol(region_fields) then
      region = region_fields
      fields = terralib.newlist({data.newtuple()})
    else
      region = region_fields.region
      fields = region_fields.fields
    end
    assert(terralib.issymbol(region) and terralib.islist(fields))
    for _, field in ipairs(fields) do
      privileges:insert(data.map_from_table {
        node_type = "privilege",
        region = region,
        field_path = field,
        privilege = privilege,
      })
    end
  end
  return privileges
end

-- #####################################
-- ## Coherence Modes
-- #################

std.exclusive = "exclusive"
std.atomic = "atomic"
std.simultaneous = "simultaneous"
std.relaxed = "relaxed"

-- #####################################
-- ## Flags
-- #################

std.no_access_flag = "no_access_flag"

-- #####################################
-- ## Conditions
-- #################

std.arrives = "arrives"
std.awaits = "awaits"

-- #####################################
-- ## Constraints
-- #################

function std.constraint(lhs, rhs, op)
  return {
    lhs = lhs,
    rhs = rhs,
    op = op,
  }
end

-- #####################################
-- ## Tasks
-- #################

local task = {}
task.__index = task

function task:set_param_symbols(t)
  assert(rawget(self, "param_symbols") == nil)
  self.param_symbols = t
end

function task:get_param_symbols()
  assert(rawget(self, "param_symbols") ~= nil)
  return self.param_symbols
end

function task:set_params_struct(t)
  assert(rawget(self, "params_struct") == nil)
  self.params_struct = t
end

function task:get_params_struct()
  assert(rawget(self, "params_struct") ~= nil)
  return self.params_struct
end

function task:set_params_map_type(t)
  assert(rawget(self, "params_map_type") == nil)
  self.params_map_type = t
end

function task:get_params_map_type()
  assert(rawget(self, "params_map_type") ~= nil)
  return self.params_map_type
end

function task:set_params_map(t)
  assert(rawget(self, "params_map") == nil)
  self.params_map = t
end

function task:get_params_map()
  assert(rawget(self, "params_map") ~= nil)
  return self.params_map
end

function task:set_field_id_params(t)
  assert(rawget(self, "field_id_params") == nil)
  self.field_id_params = t
end

function task:get_field_id_params()
  assert(rawget(self, "field_id_params") ~= nil)
  return self.field_id_params
end

function task:settype(t)
  self.type = t
end

function task:setcuda(cuda)
  self.cuda = cuda
end

function task:setinline(inline)
  self.inline = inline
end

function task:setast(node)
  self.ast = node
end

local global_kernel_id = 1
function task:addcudakernel(kernel)
  if rawget(self, "cudakernels") == nil then
    self.cudakernels = {}
  end
  local kernel_id = global_kernel_id
  local kernel_name = self.name:mkstring("", "_", "") .. "_cuda" .. tostring(kernel_id)
  self.cudakernels[kernel_id] = {
    name = kernel_name,
    kernel = kernel,
  }
  global_kernel_id = global_kernel_id + 1
  return kernel_id
end

function task:gettype()
  assert(rawget(self, "type") ~= nil)
  return self.type
end

function task:setprivileges(t)
  assert(rawget(self, "privileges") == nil)
  self.privileges = t
end

function task:getprivileges()
  assert(rawget(self, "privileges") ~= nil)
  return self.privileges
end

function task:set_coherence_modes(t)
  assert(rawget(self, "coherence_modes") == nil)
  self.coherence_modes = t
end

function task:get_coherence_modes()
  assert(rawget(self, "coherence_modes") ~= nil)
  return self.coherence_modes
end

function task:set_flags(t)
  assert(rawget(self, "flags") == nil)
  self.flags = t
end

function task:get_flags()
  assert(rawget(self, "flags") ~= nil)
  return self.flags
end

function task:set_conditions(t)
  assert(rawget(self, "conditions") == nil and t)
  self.conditions = t
end

function task:get_conditions()
  assert(rawget(self, "conditions") ~= nil)
  return self.conditions
end

function task:set_param_constraints(t)
  assert(rawget(self, "param_constraints") == nil)
  self.param_constraints = t
end

function task:get_param_constraints()
  assert(rawget(self, "param_constraints") ~= nil)
  return self.param_constraints
end

function task:set_constraints(t)
  assert(rawget(self, "constraints") == nil)
  self.constraints = t
end

function task:get_constraints()
  assert(rawget(self, "constraints") ~= nil)
  return self.constraints
end

function task:set_region_universe(t)
  assert(rawget(self, "region_universe") == nil)
  self.region_universe = t
end

function task:get_region_universe()
  assert(rawget(self, "region_universe") ~= nil)
  return self.region_universe
end

function task:set_config_options(t)
  assert(rawget(self, "config_options") == nil)
  self.config_options = t
end

function task:get_config_options()
  assert(rawget(self, "config_options") ~= nil)
  return self.config_options
end

function task:settaskid(taskid)
  self.taskid = taskid
end

function task:gettaskid()
  return self.taskid
end

function task:getname()
  return self.name
end

function task:getdefinition()
  return self.definition
end

function task:getcuda()
  return self.cuda
end

function task:getcudakernels()
  return self.cudakernels
end

function task:getinline()
  return self.inline
end

function task:getast()
  return self.ast
end

function task:is_variant_task()
  if rawget(self, "source_variant") then
    return true
  else
    return false
  end
end

function task:set_source_variant(source_variant)
  self.source_variant = source_variant
end

function task:get_source_variant()
  assert(rawget(self, "source_variant") ~= nil)
  return self.source_variant
end

function task:make_variant()
  local variant_task = std.newtask(self.name)
  variant_task:settaskid(self:gettaskid())
  variant_task:settype(self:gettype())
  variant_task:setprivileges(self:getprivileges())
  variant_task:set_coherence_modes(self:get_coherence_modes())
  variant_task:set_conditions(self:get_conditions())
  variant_task:set_param_constraints(self:get_param_constraints())
  variant_task:set_flags(self:get_flags())
  variant_task:set_constraints(self:get_constraints())
  variant_task:set_source_variant(self)
  return variant_task
end

function task:printpretty()
  return self:getdefinition():printpretty()
end

function task:compile()
  return self:getdefinition():compile()
end

function task:disas()
  return self:getdefinition():disas()
end

function task:__call(...)
  return self:getdefinition()(...)
end

function task:__tostring()
  return tostring(self:getname())
end

function std.newtask(name)
  assert(data.is_tuple(name))
  local terra proto
  proto.name = name:mkstring(".")
  return setmetatable({
    definition = proto,
    taskid = terralib.global(c.legion_task_id_t),
    name = name,
    cuda = false,
    inline = false,
  }, task)
end

function std.is_task(x)
  return getmetatable(x) == task
end

-- #####################################
-- ## Fspaces
-- #################

local fspace = {}
fspace.__index = fspace

fspace.__call = terralib.memoize(function(fs, ...)
  -- Do NOT attempt to access fs.params or fs.fields; they are not ready yet.

  local args = terralib.newlist({...})
  -- Complain early if args are not symbols, but don't check types
  -- yet, since they may not be there at this point.
  for i, arg in ipairs(args) do
    if not terralib.issymbol(arg) then
      error("expected a symbol as argument " .. tostring(i) .. ", got " .. tostring(arg))
    end
  end

  local st = terralib.types.newstruct(fs.name)
  st.is_fspace_instance = true
  st.fspace = fs
  st.args = args

  function st:getparams()
    return rawget(self, "params") or self.fspace.params
  end

  function st:getconstraints()
    st:getentries() -- Computes constraints as well.
    local constraints = rawget(self, "__constraints")
    assert(constraints)
    return constraints
  end

  function st.metamethods.__getentries(st)
    local params = st:getparams()
    local fields = rawget(st, "fields") or fs.fields
    local constraints = rawget(st, "constraints") or fs.constraints
    assert(params and fields, "Attempted to complete fspace too early.")

    std.validate_args(fs.node, params, args, false, terralib.types.unit, {}, true)

    local entries, st_constraints = std.validate_fields(fields, constraints, params, args)
    st.__constraints = st_constraints
    return entries
  end

  function st:force_cast(from, to, expr)
    if from:ispointer() then
      from = from.type
    end
    assert(std.is_fspace_instance(from) and std.is_fspace_instance(to) and
             from.fspace == to.fspace)

    local v = terralib.newsymbol()
    local fields = terralib.newlist()
    for i, to_field in ipairs(to:getentries()) do
      local from_field = from:getentries()[i]

      fields:insert(
        std.implicit_cast(from_field.type, to_field.type, `(v.[to_field.field])))
    end

    return quote var [v] = [expr] in [to]({ [fields] }) end
  end

  function st.metamethods.__typename(st)
    return st.fspace.name .. "(" .. st.args:mkstring(", ") .. ")"
  end

  return st
end)

function std.newfspace(node, name, has_params)
  local fs = setmetatable({node = node, name = name}, fspace)
  if not has_params then
    fs = fs()
  end
  return fs
end

-- #####################################
-- ## Codegen Helpers
-- #################

local gen_optimal = terralib.memoize(
  function(op, lhs_type, rhs_type)
    return terra(lhs : lhs_type, rhs : rhs_type)
      if [std.quote_binary_op(op, lhs, rhs)] then
        return lhs
      else
        return rhs
      end
    end
  end)

std.fmax = macro(
  function(lhs, rhs)
    local lhs_type, rhs_type = lhs:gettype(), rhs:gettype()
    local result_type = std.type_meet(lhs_type, rhs_type)
    assert(result_type)
    return `([gen_optimal(">", lhs_type, rhs_type)]([lhs], [rhs]))
  end)

std.fmin = macro(
  function(lhs, rhs)
    local lhs_type, rhs_type = lhs:gettype(), rhs:gettype()
    local result_type = std.type_meet(lhs_type, rhs_type)
    assert(result_type)
    return `([gen_optimal("<", lhs_type, rhs_type)]([lhs], [rhs]))
  end)

function std.quote_unary_op(op, rhs)
  if op == "-" then
    return `(-[rhs])
  elseif op == "not" then
    return `(not [rhs])
  else
    assert(false, "unknown operator " .. tostring(op))
  end
end

function std.quote_binary_op(op, lhs, rhs)
  if op == "*" then
    return `([lhs] * [rhs])
  elseif op == "/" then
    return `([lhs] / [rhs])
  elseif op == "%" then
    return `([lhs] % [rhs])
  elseif op == "+" then
    return `([lhs] + [rhs])
  elseif op == "-" then
    return `([lhs] - [rhs])
  elseif op == "<" then
    return `([lhs] < [rhs])
  elseif op == ">" then
    return `([lhs] > [rhs])
  elseif op == "<=" then
    return `([lhs] <= [rhs])
  elseif op == ">=" then
    return `([lhs] >= [rhs])
  elseif op == "==" then
    return `([lhs] == [rhs])
  elseif op == "~=" then
    return `([lhs] ~= [rhs])
  elseif op == "and" then
    return `([lhs] and [rhs])
  elseif op == "or" then
    return `([lhs] or [rhs])
  elseif op == "max" then
    return `([std.fmax]([lhs], [rhs]))
  elseif op == "min" then
    return `([std.fmin]([lhs], [rhs]))
  else
    assert(false, "unknown operator " .. tostring(op))
  end
end

-- #####################################
-- ## Main
-- #################

local tasks = terralib.newlist()

function std.register_task(task)
  tasks:insert(task)
end

local reduction_ops = terralib.newlist({
    {op = "+", name = "plus"},
    {op = "-", name = "minus"},
    {op = "*", name = "times"},
    {op = "/", name = "divide"},
    {op = "max", name = "max"},
    {op = "min", name = "min"},
})

local reduction_types = terralib.newlist({
    float,
    double,
    int32,
})

std.reduction_op_ids = {}

-- Prefill the table of reduction op IDs.
do
  local base_op_id = 101
  for _, op in ipairs(reduction_ops) do
    for _, op_type in ipairs(reduction_types) do
      local op_id = base_op_id
      base_op_id = base_op_id + 1
      if not std.reduction_op_ids[op.op] then
        std.reduction_op_ids[op.op] = {}
      end
      std.reduction_op_ids[op.op][op_type] = op_id
    end
  end
end

function std.start(main_task)
  assert(std.is_task(main_task))
  local next_task_id = 0
  local task_registrations = tasks:map(
    function(task)
      local task_id
      if not task:is_variant_task() then
        next_task_id = next_task_id + 1
        task_id = next_task_id
        task:gettaskid():set(task_id)
      else
        local source_variant = task:get_source_variant()
        task_id = source_variant:gettaskid():get()
      end

      local return_type = task:getdefinition():gettype().returntype
      local result_type_bucket = std.type_size_bucket_name(return_type)
      local register = c["legion_runtime_register_task" .. result_type_bucket]

      local options = task:get_config_options()

      local proc_type = c.LOC_PROC
      if task:getcuda() then proc_type = c.TOC_PROC end

      return quote [register](
        task_id,
        proc_type,
        true,
        true,
        4294967295 --[[ AUTO_GENERATE_ID ]],
        c.legion_task_config_options_t {
          leaf = options.leaf,
          inner = options.inner,
          idempotent = options.idempotent,
        },
        [task:getname():mkstring(".")],
        [task:getdefinition()])
      end
    end)
  if std.config["cuda"] and cudahelper.check_cuda_available() then
    cudahelper.link_driver_library()
    local all_kernels = {}
    tasks:map(function(task)
      if task:getcuda() then
        local kernels = task:getcudakernels()
        if kernels ~= nil then
          for k, v in pairs(kernels) do
            all_kernels[k] = v
          end
        end
      end
    end)
    cudahelper.jit_compile_kernels_and_register(all_kernels)
  end

  local reduction_registrations = terralib.newlist()
  for _, op in ipairs(reduction_ops) do
    for _, op_type in ipairs(reduction_types) do
      local register = c["register_reduction_" .. op.name .. "_" .. tostring(op_type)]
      local op_id = std.reduction_op_ids[op.op][op_type]
      reduction_registrations:insert(
        quote
          [register](op_id)
        end)
    end
  end

  local args = std.args
  local argc = #args
  local argv = terralib.newsymbol((&int8)[argc], "argv")
  local argv_setup = terralib.newlist({quote var [argv] end})
  for i, arg in ipairs(args) do
    argv_setup:insert(quote
      [argv][ [i - 1] ] = [arg]
    end)
  end

  local terra main()
    [argv_setup];
    [task_registrations];
    [reduction_registrations]
    c.legion_runtime_set_top_level_task_id([main_task:gettaskid()])
    return c.legion_runtime_start(argc, argv, false)
  end
  main()
end

-- #####################################
-- ## Vector Operators
-- #################
do
  local to_math_op_name = {}
  local function math_op_factory(fname)
    return terralib.memoize(function(arg_type)
      local intrinsic_name = "llvm." .. fname .. "."
      local elmt_type = arg_type
      if arg_type:isvector() then
        intrinsic_name = intrinsic_name .. "v" .. arg_type.N
        elmt_type = elmt_type.type
      end
      assert(elmt_type == float or elmt_type == double)
      intrinsic_name = intrinsic_name .. "f" .. (sizeof(elmt_type) * 8)
      local op = terralib.intrinsic(intrinsic_name, arg_type -> arg_type)
      to_math_op_name[op] = fname
      return op
    end)
  end

  local supported_math_ops = {
    "ceil",
    "cos",
    "exp",
    "exp2",
    "fabs",
    "floor",
    "log",
    "log2",
    "log10",
    "sin",
    "sqrt",
    "trunc"
  }

  for _, fname in pairs(supported_math_ops) do
    std[fname] = math_op_factory(fname)
  end

  function std.is_math_op(op)
    return to_math_op_name[op] ~= nil
  end

  function std.convert_math_op(op, arg_type)
    return std[to_math_op_name[op]](arg_type)
  end
end

do
  local intrinsic_names = {}
  intrinsic_names[vector(float,  4)] = "llvm.x86.sse.%s.ps"
  intrinsic_names[vector(double, 2)] = "llvm.x86.sse2.%s.pd"
  intrinsic_names[vector(float,  8)] = "llvm.x86.avx.%s.ps.256"
  intrinsic_names[vector(double, 4)] = "llvm.x86.avx.%s.pd.256"

  local function math_binary_op_factory(fname)
    return terralib.memoize(function(arg_type)
      assert(arg_type:isvector())
      assert((arg_type.type == float and 4 <= arg_type.N and arg_type.N <= 8) or
             (arg_type.type == double and 2 <= arg_type.N and arg_type.N <= 4))

      local intrinsic_name = string.format(intrinsic_names[arg_type], fname)
      return terralib.intrinsic(intrinsic_name,
                                {arg_type, arg_type} -> arg_type)
    end)
  end

  local supported_math_binary_ops = { "min", "max", }
  for _, fname in pairs(supported_math_binary_ops) do
    std["v" .. fname] = math_binary_op_factory(fname)
  end

  function std.is_minmax_supported(arg_type)
    assert(not (std.is_ref(arg_type) or std.is_rawref(arg_type)))
    if not arg_type:isvector() then return false end
    if not ((arg_type.type == float and
             4 <= arg_type.N and arg_type.N <= 8) or
            (arg_type.type == double and
             2 <= arg_type.N and arg_type.N <= 4)) then
      return false
    end
    return true
  end
end

return std

