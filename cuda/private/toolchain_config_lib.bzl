load(
    "@bazel_tools//tools/cpp:cc_toolchain_config_lib.bzl",
    _action_config = "action_config",
    _artifact_name_pattern = "artifact_name_pattern",
    _feature = "feature",
    _feature_set = "feature_set",
    _flag_group = "flag_group",
    _flag_set = "flag_set",
    _tool = "tool",
    _variable_with_value = "variable_with_value",
)

CudaToolchainConfigInfo = provider(
    """""",
    fields = {
        "features": "A list of features.",
        "artifact_name_patterns": "A list of artifact_name_patterns.",
    },
)

_MAX_FLAG_LEN = 1024

def _tok_var(chars):
    if len(chars) == 0 or chars[-1] != "{":
        fail("expected '{'")
    chars.pop()
    var = []
    if len(chars) and (chars[-1].isalnum() or chars[-1] == "_"):
        var.append(chars.pop())
    else:
        fail("expected variable name")
    for i in range(_MAX_FLAG_LEN + 1):
        if len(chars) and chars[-1].isalnum() or chars[-1] in "._":
            var.append(chars.pop())
        else:
            break
    if len(chars) and chars[-1] == "}":
        chars.pop()
    else:
        fail("expected '}'")
    return "".join(var)

_FlagInfo = provider(
    "",
    fields = {
        "chunks": "",
        "expandables": "",
    },
)

def _copy_flag_info(flag_info):
    expandables = {}
    for k, v in flag_info.expandables.items():
        expandables[k] = v[:]
    return _FlagInfo(
        chunks = flag_info.chunks[:],
        expandables = expandables,
    )

def parse_flag(raw_flag, cache = None):
    if len(raw_flag) > _MAX_FLAG_LEN:
        fail(raw_flag, "is too long!")
    if cache != None and raw_flag in cache:
        return _copy_flag_info(cache[raw_flag])
    curr = None
    chars = reversed(list(raw_flag.elems()))
    result = []
    expandable_indices = []
    for i in range(_MAX_FLAG_LEN + 1):
        if len(chars) == 0:
            break
        if curr == None:
            curr = chars.pop()
        if curr == "%":
            if len(chars) and chars[-1] == "%":
                result.append(chars.pop())
            else:
                expandable_indices.append(len(result))
                result.append(_tok_var(chars))
            curr = None
            continue
        result.append(curr)
        curr = None

    compact_result = []
    compact_expandable_indices = []
    expandables = {}

    tmp = []
    for i, r in enumerate(result):
        if i in expandable_indices:
            if len(tmp):
                compact_result.append("".join(tmp))
            compact_expandable_indices.append(len(compact_result))
            compact_result.append(r)
            tmp = []
        else:
            tmp.append(r)
    if len(tmp):
        compact_result.append("".join(tmp))

    for i in compact_expandable_indices:
        expandables.setdefault(compact_result[i], [])
    for i in compact_expandable_indices:
        expandables[compact_result[i]].append(i)

    flag_info = _FlagInfo(
        chunks = compact_result,
        expandables = expandables,
    )
    if cache != None:
        cache[raw_flag] = _copy_flag_info(flag_info)
    return flag_info

_NestingVarInfo = provider(
    """""",
    fields = {
        "parent": "",
        "this": "",
    },
)

_VAR_NESTING_MAX_DEPTH = 64

def _single_access(value, path_list, ret):
    v = value
    for i, name in enumerate(path_list):
        if hasattr(v, name):
            v = getattr(v, name)
        else:
            return False
    ret.append(v)
    return True

def exist(input_var, path = None, path_list = None):
    if path_list == None:
        path_list = path.split(".")
    var = None
    parent_nesting_var = input_var
    for _ in range(_VAR_NESTING_MAX_DEPTH):
        if parent_nesting_var == None:
            break
        var = parent_nesting_var.this
        parent_nesting_var = parent_nesting_var.parent
        if _single_access(var, path_list, []):
            return True
    return False

def access(var, path = None, path_list = None, fail_if_not_available = True):
    if path_list == None:
        path_list = path.split(".")
    ret = []
    value = None
    parent_nesting_var = var
    for _ in range(_VAR_NESTING_MAX_DEPTH):
        if parent_nesting_var == None:
            break
        value = parent_nesting_var.this
        parent_nesting_var = parent_nesting_var.parent
        if _single_access(value, path_list, ret):
            return ret[0]
    if fail_if_not_available:
        fail("Cannot access", ".".join(path_list))
    else:
        return None

def eval_env_entry(ee, var, environ):
    if ee.key in environ:
        fail("key", ee.key, "occurs in multiple env_entry, unable to handle conflict.")
    environ[ee.key] = access(var, ee.value)

def eval_env_set(es, var):
    fail("NotImplemented")

def create_var_from_value(value, parent = None, path = None, path_list = None):
    if path == None and path_list == None:
        return _NestingVarInfo(this = value, parent = parent)
    if path_list == None:
        path_list = path.split(".")
    v = value
    for i in range(len(path_list) - 1, -1, -1):
        name = path_list[i]
        v = struct(**{name: v})
    return _NestingVarInfo(this = v, parent = parent)

def expand_flag(flag_info, var, name):
    if len(flag_info.expandables) == 0 or name not in flag_info.expandables:
        return
    if not exist(var, name):
        return
    value = access(var, name)
    if type(value) != "string":
        fail("Cannot expand variable '" + name + "': expected string, found", value)
    for i in flag_info.expandables[name]:
        flag_info.chunks[i] = value
    flag_info.expandables.pop(name)

def _can_be_expanded(fg, var):
    if fg.expand_if_available != None and not exist(var, fg.expand_if_available):
        return False
    if fg.expand_if_not_available != None and exist(var, fg.expand_if_not_available):
        return False
    if fg.expand_if_true != None and access(var, fg.expand_if_true, fail_if_not_available = False) not in [True, 1]:
        return False
    if fg.expand_if_false != None and access(var, fg.expand_if_false, fail_if_not_available = False) not in [False, 0]:
        return False
    if fg.expand_if_equal != None and (not exist(var, fg.expand_if_equal.name) or access(var, fg.expand_if_equal.name) != fg.expand_if_equal.value):
        return False
    return True

def _expand_flag_infos_in_current_scope(flag_infos, var):
    for flag_info in flag_infos:
        for name in flag_info.expandables.keys():
            expand_flag(flag_info, var, name)

def _eval_flags_or_flag_groups(stack, ret, fg, var, recursion_depth, parse_flag_cache):
    if len(fg.flags) > 0 and len(fg.flag_groups) == 0:
        # no need to reverse, because it is not push stack
        flag_infos = [parse_flag(flag_str, parse_flag_cache) for flag_str in fg.flags]
        _expand_flag_infos_in_current_scope(flag_infos, var)
        ret[-1].extend(flag_infos)
    elif len(fg.flags) == 0 and len(fg.flag_groups) > 0:
        # reverse push stack, so that we can maintain in-order transverse
        for i in range(len(fg.flag_groups) - 1, -1, -1):
            stack.append([fg.flag_groups[i], var, recursion_depth + 1, False])
    else:
        fail(fg, "is invalid, either flags or flag_groups must be specified.")

def _eval_flag_group_impl(stack, ret, fg, var, eval_iterations):
    parse_flag_cache = {}
    stack.append([fg, var, 1, False])
    recursion_depth = 0
    for _ in range(eval_iterations):
        if len(stack) == 0:
            break
        fg, var, recursion_depth, entered = stack[-1]
        if entered:  # return from a recursive call. We need to handle the returned value.
            # Since we are returning from another function, the variable socpe is different,
            # we need to expand all flags in current scope again.
            _expand_flag_infos_in_current_scope(ret[-1], var)
            if len(ret) >= 2:
                ret[-2].extend(ret[-1])
                ret.pop()  # The return space is deallocated.
            stack.pop()  # The stack frame is useless anymore,
            continue  #### and there is no need to procees the current stack frame any further

        stack[-1][-1] = True  # mark entered = True

        if recursion_depth == len(ret) + 1:
            # We recurse into a new stackframe, that call will have return value.
            # Set up the return space for it.
            ret.append([])
        else:
            fail("Invalid recursion_depth change, original depth", len(ret), "current depth", recursion_depth)

        if _can_be_expanded(fg, var):
            if fg.iterate_over != None:
                iterated_over_values = access(var, fg.iterate_over)
                if type(iterated_over_values) != "list":
                    fail(fg.iterate_over, "is not an iterable")

                path_list = fg.iterate_over.split(".")
                if len(fg.flags) != 0:  # expanding flags
                    # expanding flags should iterate in order, no more recursion involved
                    for value in iterated_over_values:
                        new_var = create_var_from_value(value, parent = var, path_list = path_list)
                        _eval_flags_or_flag_groups(stack, ret, fg, new_var, recursion_depth, parse_flag_cache)
                else:  # expanding flag_groups
                    # expanding flag_groups should iterate in reversed order due to recursion
                    for value in reversed(iterated_over_values):
                        new_var = create_var_from_value(value, parent = var, path_list = path_list)
                        _eval_flags_or_flag_groups(stack, ret, fg, new_var, recursion_depth, parse_flag_cache)
            else:
                _eval_flags_or_flag_groups(stack, ret, fg, var, recursion_depth, parse_flag_cache)

    if len(stack) != 0:
        fail("flag_group evaluation imcomplete")
    return ret

def eval_flag_group(fg, value, max_eval_iterations = 65536):
    ret = []
    _eval_flag_group_impl([], ret, fg, create_var_from_value(value), max_eval_iterations)
    processed_ret = []
    for flag_info in ret[0]:
        if len(flag_info.expandables) != 0:
            fail(flag_info, "is not fully expanded")
        processed_ret.append("".join(flag_info.chunks))
    return processed_ret

def eval_feature(feat, current_action, vars):
    ret = []
    if not feat.enabled:
        return ret
    enabled = False
    for fs in feat.flag_sets:
        if len(fs.with_features) != 0:
            fail("NotImplemented")
        if current_action in fs.actions:
            for fg in fs.flag_groups:
                pass
    return ret

_AllSelectablesInfo = provider(
    "",
    fields = {
        "implies": "",
        "implied_by": "",
        "requires": "",
        "required_by": "",
        "requested": "",
        "enabled": "",
    },
)

def _collect_selectables_info(selectables, requested):
    info = _AllSelectablesInfo(
        implies = {},
        implied_by = {},
        requires = {},
        required_by = {},
        requested = {r: True for r in requested},
        enabled = {},
    )
    for selectable in selectables:
        if not hasattr(selectable, "implies"):
            fail(selectable, "is not an selectable")
        name = _get_name_from_selectable(selectable)

        if selectable.enabled:
            info.enabled[name] = True

        info.implies[name] = selectable.implies[:]
        for i in selectable.implies:
            info.implied_by.setdefault(i, [])
            info.implied_by[i].append(name)

        if hasattr(selectable, "requires"):  # NOTE: action_config do not has this field
            info.requires[name] = [required_feature_set.features[:] for required_feature_set in selectable.requires]
            for required_feature_set_names in info.requires[name]:
                for r in required_feature_set_names:
                    info.required_by.setdefault(r, [])
                    info.required_by[r].append(name)
    return info

def _get_name_from_selectable(selectable):
    if hasattr(selectable, "name"):
        return selectable.name
    if hasattr(selectable, "action_name"):
        return selectable.action_name
    fail("Unreachable")

def _is_enabled(info, name):
    return info.enabled.get(name, False)

def _enable_all_implied(info):
    _MAX_ITER = 65536

    to_enable = reversed(info.requested.keys())[:]

    for _ in range(_MAX_ITER):
        if len(to_enable) == 0:
            break
        name = to_enable.pop()
        if name in info.implies and name not in info.enabled:
            info.enabled[name] = True
            to_enable.extend([new_name for new_name in reversed(info.implies[name])])

    if len(to_enable) != 0:
        fail("_enable_all_implied imcomplete")

def _is_implied_by_enabled_activatable(info, name):
    for implied_by in info.implied_by[name]:
        if _is_enabled(info, implied_by):
            return True
    return False

def _all_implications_enabled(info, name):
    for implied in info.implies[name]:
        if not _is_enabled(info, implied):
            return False
    return True

def _all_requirements_met(info, name):
    if len(info.requires.get(name, [])) == 0:
        return True
    for requires_all_of in info.requires[name]:
        req_met = True
        for required in requires_all_of:
            if not _is_enabled(info, required):
                req_met = False
                break
        if req_met:
            return True
    return False

def _is_satisfied(info, name):
    # print((name in info.requested or _is_implied_by_enabled_activatable(info, name)), _all_implications_enabled(info, name), _all_requirements_met(info, name))
    return ((name in info.requested or _is_implied_by_enabled_activatable(info, name)) and
            _all_implications_enabled(info, name) and
            _all_requirements_met(info, name))

def _check_activatable(info, to_check):
    _MAX_ITER = 65536
    for _ in range(_MAX_ITER):
        if len(to_check) == 0:
            break
        name = to_check.pop()

        if not _is_enabled(info, name) or _is_satisfied(info, name):
            # print("keep", name)
            continue

        # print("disable", name)
        info.enabled[name] = False

        # Once we disable a selectable, we have to re-check all selectables
        # that can be affected by that removal. Notice this is a loop unrolled
        # recursive function, we should reversed the order here!

        # 3. A selectable that this selectable implied may now be disabled if
        # no other selectables also implies it.
        to_check.extend(reversed(info.implies.get(name, [])))

        # 2. A selectable that required the current selectable may now be
        # disabled, depending on whether the requirement was optional.
        to_check.extend(reversed(info.required_by.get(name, [])))

        # 1. A selectable that implied the current selectable is now going to
        # be disabled.
        to_check.extend(reversed(info.implied_by.get(name, [])))

    if len(to_check) != 0:
        fail("_check_activatable imcomplete")

def _disable_unsupported_activatables(info):
    enabled = [k for k, v in reversed(info.enabled.items()) if v == True]
    _check_activatable(info, enabled)

def get_enabled_selectables(selectables, requested = None):
    info = _collect_selectables_info(selectables, requested if requested != None else [])
    _enable_all_implied(info)
    _disable_unsupported_activatables(info)
    return sorted([k for k, v in info.enabled.items() if v == True])

action_config = _action_config
artifact_name_pattern = _artifact_name_pattern
feature = _feature
feature_set = _feature_set
flag_group = _flag_group
flag_set = _flag_set
tool = _tool
variable_with_value = _variable_with_value