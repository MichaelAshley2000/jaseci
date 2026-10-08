"""CI-only diagnostic: failed Mongo writes must be observable to commit callers."""

import json;
import from unittest.mock { patch }
import from pymongo.collection { Collection }
import from pymongo.errors { AutoReconnect }
import from jaclang.jac0core.runtime { JacRuntime }
import from jaclang.scale.memory.memory_hierarchy { MongoBackend }
import from jaclang.runtimelib.changeset { ChangeSet }
import from runtime_cache_fixture { CacheFixture }


test "a failed authoritative Mongo field write cannot be acknowledged as a committed context" {
    prior = JacRuntime.get_context();
    fixture = CacheFixture();
    try {
        fixture.seed();
        writer = fixture.context();
        project = fixture.project(writer);
        project.preview_sandbox_id = "sandbox-failed-write";
        original_update: any = Collection.update_one;
        original_apply: any = MongoBackend.apply;
        observed: dict[(str, any)] = {"write_failed": False, "report": None};

        def fail_target_write(
            collection: any, query: dict, update: dict, upsert: bool = False
        ) -> any {
            if str(query.get("_id", "")) == str(fixture.project_id) {
                observed["write_failed"] = True;
                raise AutoReconnect("simulated transient Mongo write failure");
            }
            return original_update(collection, query, update, upsert=upsert);
        }

        def capture_apply(backend: any, changeset: ChangeSet) -> any {
            result = original_apply(backend, changeset);
            if backend is writer.mem.l3 {
                observed["report"] = result;
            }
            return result;
        }

        raised = False;
        with patch.object(Collection, "update_one", fail_target_write), patch.object(
            MongoBackend, "apply", capture_apply
        ) {
            try {
                writer.mem.commit();
            } except Exception {
                raised = True;
            }
        }
        apply_result: any = observed["report"];
        assert observed["write_failed"] , "the Mongo driver failure must be reached";
        assert apply_result is not None , "capture the real Mongo apply return";
        assert str(fixture.project_id) in {str(key) for key in apply_result.failed};
        assert not apply_result.ok();
        evidence = fixture.witness("mongo-write-failed-but-commit-returned");
        assert evidence["mongo"]["preview_sandbox_id"] == "";
        assert evidence["fresh_context_owner"] == evidence["owner_root"];
        print(
            json.dumps(
                {
                    "schedule": "ordinary-mongo-write-failure",
                    "project_anchor": str(fixture.project_id),
                    "commit_raised": raised,
                    "context_marked_committed": writer.mem._committed,
                    "changes_cleared": writer.mem.changes.is_empty(),
                    "apply_failed_count": len(apply_result.failed),
                    "apply_conflict_count": len(apply_result.conflicts),
                    "mongo_pointer": evidence["mongo"]["preview_sandbox_id"]
                },
                sort_keys=True
            )
        );
        assert raised , "commit callers must observe an authoritative write failure";
    } finally {
        if fixture.collection is not None {
            fixture.cleanup();
        }
        JacRuntime.set_context(prior);
    }
}
