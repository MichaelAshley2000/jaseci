"""CI-only owner witness around an unchanged Builder registry regression."""

import json;
import sys;
import from unittest.mock { patch }
import from pymongo.collection { Collection }
import from jaclang { JacRuntime as Jac }

glob original_insert: any = Collection.insert_one;
glob observed: list = [];


"""Delegate the driver call and record only registry identity and ownership."""
def observe_insert(collection: any, document: dict, *args: any, **kwargs: any) -> any {
    result = original_insert(collection, document, *args, **kwargs);
    if document.get("arch_type", "") == "McpRegistry" {
        ctx: any = Jac.get_context();
        record = {
            "event": "registry_insert_owner_witness",
            "registry_id": str(document.get("_id", "")),
            "stored_owner_root": str(document.get("data", {}).get("root", "")),
            "caller_root": str(ctx.user_root.id) if ctx.user_root else ""
        };
        observed.append(record);
        sys.stdout.write(json.dumps(record, sort_keys=True) + chr(10));
        sys.stdout.flush();
    }
    return result;
}


with entry {
    with patch.object(Collection, "insert_one", observe_insert) {
        failures = Jac.run_test(
            filepath="tests/jachammer/coder_root_walk_test.jac", verbose=True
        );
    }
    assert len(observed) == 2 , "the clone and original registry inserts must both be observed";
    sys.stdout.write(
        json.dumps(
            {"event": "unchanged_registry_test_result", "failures": failures},
            sort_keys=True
        ) + chr(10)
    );
    sys.exit(1 if failures else 0);
}
