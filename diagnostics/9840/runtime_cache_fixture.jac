"""Disposable owner contexts for CI-only Mongo/Redis diagnostics."""

import json;
import os;
import from uuid { UUID, uuid4 }
import from unittest.mock { patch }
import from jaclang.jac0core.runtime { JacRuntime }
import from jaclang.jac0core.archetype { Root }
import from jaclang.runtimelib.context { ExecutionContext }
import from jaclang.runtimelib.utils { storage_key }
import from jaclang.scale.memory.memory_hierarchy {
    MongoBackend,
    RedisBackend,
    ScaleTieredMemory
}

node CacheWitness {
    has preview_sandbox_id: str = "",
        updated_at: str = "seed";
}

obj CacheFixture {
    has db_name: str = "jac_cache_repro_" + uuid4().hex,
        contexts: list[any] = [],
        owner_id: any = None,
        project_id: any = None,
        collection: any = None;

    def context() -> any {
        assert os.environ.get("MONGODB_URI") , "CI must provide Mongo";
        assert os.environ.get("REDIS_URL") , "CI must provide Redis";
        mongo = MongoBackend(mongo_url=os.environ["MONGODB_URI"], db_name=self.db_name);
        cache = RedisBackend(redis_url=os.environ["REDIS_URL"]);
        assert mongo.is_available() and cache.is_available();
        memory = ScaleTieredMemory();
        memory.l3 = mongo;
        memory.l2 = cache;
        memory._cache_available = True;
        ctx = ExecutionContext();
        ctx.mem = memory;
        self.contexts.append(ctx);
        self.collection = mongo.collection;
        JacRuntime.set_context(ctx);
        if self.owner_id is not None {
            ctx.set_user_root(str(self.owner_id));
        }
        return ctx;
    }

    def seed() -> None {
        ctx = self.context();
        owner: any = Root();
        owner_anchor: any = owner.__jac__;
        owner_anchor.persistent = True;
        self.owner_id = owner_anchor.id;
        ctx.mem.__mem__[owner_anchor.id] = owner_anchor;
        ctx.user_root = owner_anchor;
        ctx.entry_node = owner_anchor;
        project: any = root ++> CacheWitness();
        project_anchor: any = project.__jac__;
        self.project_id = project_anchor.id;
        ctx.mem.commit();
    }

    def project(ctx: any) -> any {
        JacRuntime.set_context(ctx);
        anchor = ctx.mem.get(self.project_id);
        assert anchor is not None;
        return anchor.archetype;
    }

    def witness(schedule: str) -> dict {
        doc = self.collection.find_one({"_id": str(self.project_id)});
        assert doc is not None;
        redis_anchor = self.contexts[0].mem.l2.get(self.project_id);
        observer = self.context();
        owner_projects = [root-->][?:CacheWitness];
        assert len(owner_projects) == 1;
        observed = owner_projects[0];
        result = {
            "schedule": schedule,
            "owner_root": str(self.owner_id),
            "project_anchor": str(self.project_id),
            "mongo": doc["data"]["archetype"],
            "mongo_version": doc["data"].get("version"),
            "redis_present": redis_anchor is not None,
            "redis_pointer": redis_anchor.archetype.preview_sandbox_id
                if redis_anchor is not None
                else None,
            "redis_updated_at": redis_anchor.archetype.updated_at
                if redis_anchor is not None
                else None,
            "redis_version": redis_anchor.version if redis_anchor is not None else None,
            "fresh_context_pointer": observed.preview_sandbox_id,
            "fresh_context_updated_at": observed.updated_at,
            "fresh_context_owner": str(observer.user_root.id)
        };
        print(json.dumps(result, sort_keys=True));
        return result;
    }

    def cleanup() -> None {
        ids = [UUID(doc["_id"]) for doc in self.collection.find({}, {"_id": 1})];
        # Remove only this fixture's unique anchors and database.
        for ctx in self.contexts {
            ctx.mem._committed = True;
            ctx.close();
        }
        # Backends' close clears their client field; retain the process clients
        # through dedicated backend handles for scoped cleanup.
        mongo = MongoBackend(mongo_url=os.environ["MONGODB_URI"], db_name=self.db_name);
        cache = RedisBackend(redis_url=os.environ["REDIS_URL"]);
        redis_client: any = cache.redis_client;
        mongo_client: any = mongo.client;
        for anchor_id in ids {
            redis_client.delete(storage_key(anchor_id));
        }
        mongo_client.drop_database(self.db_name);
    }
}

