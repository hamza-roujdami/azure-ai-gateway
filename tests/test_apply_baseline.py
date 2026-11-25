import copy

import pytest

from apply_baseline import daily_cost_ceiling, load_baseline, merge

GATEWAY = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.ApiManagement/aigateways/gw"


def test_repository_baseline_is_valid_and_has_a_daily_cost_ceiling():
    assert daily_cost_ceiling(load_baseline()) == 25


def test_merge_updates_in_place_keeps_other_policies_and_ids():
    current = [
        {"type": "costLimit", "id": "keep-me", "amount": 10, "period": "day", "overrides": [{"amount": 1}]},
        {"type": "ipFilter", "scope": "resource", "action": "Allow", "cidrRanges": ["10.0.0.0/8"]},
    ]
    baseline = [{"type": "costLimit", "amount": 25, "period": "day"}, {"type": "tokenLimit", "count": 5}]
    merged = merge(copy.deepcopy(current), baseline, GATEWAY)
    assert merged[0] == {**current[0], "amount": 25}
    assert merged[1] == current[1]
    assert merged[2] == {"type": "tokenLimit", "count": 5}


def test_new_cost_limit_gets_a_stable_id_so_reruns_change_nothing():
    baseline = [{"type": "costLimit", "amount": 25, "period": "day"}]
    first = merge([], baseline, GATEWAY)
    assert first[0]["id"] and merge(first, baseline, GATEWAY) == first


def test_duplicate_types_are_rejected(tmp_path):
    path = tmp_path / "b.json"
    path.write_text('[{"type": "tokenLimit"}, {"type": "tokenLimit"}]')
    with pytest.raises(ValueError, match="twice"):
        load_baseline(path)
