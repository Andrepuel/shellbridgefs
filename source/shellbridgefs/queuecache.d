module shellbridgefs.queuecache;

string ptrToString(T)(T* a) {
	import std.conv : to;

	if (a is null) {
		return "null";
	} else {
		return a.to!string ~ ":" ~ (*a).to!string;
	}
}

struct QueueCache(K, V, size_t N = 512) {
	struct Value {
		K key;
		V value;
		
		Value* next;
		Value* prev;

		invariant {
			assert(next !is &this);
			assert(prev !is &this);
		}
	}

	Value* first;
	Value* last;
	Value[K] cache;

	Value[] cacheOrder() {
		Value[] r;
		Value* each = first;
		while(each !is null) {
			r ~= *each;
			each = each.next;
		}
		return r;
	}

	Value* insert(K k, V v) {
		assert(k !in cache);
		Value* r = &(cache[k] = Value(k, v));
		if (last !is null) {
			last.next = r;
		}
		if (first is null) {
			first = r;
		}
		r.prev = last;
		last = r;
		return r;
	}

	Value popFront() {
		if (first.next !is null) {
			first.next.prev = null;
		}
		cache.remove(first.key);
		Value r = *first;
		if (last == first) {
			last = null;
		}
		first = first.next;
		return r;
	}

	Value popBack() {
		if (last.prev !is null) {
			last.prev.next = null;
		}
		cache.remove(last.key);
		Value r = *last;
		if (first == last) {
			first = null;
		}
		last = last.prev;
		return r;
	}

	void moveBack(Value* value) {
		if (last is value) {
			return;
		}

		if (value.prev !is null) {
			value.prev.next = value.next;
		}
		if (value.next !is null) {
			value.next.prev = value.prev;
		}
		value.next = null;
		value.prev = last;
		if (last !is null) {
			last.next = value;
		}
		last = value;
	}

	V fetch(K key, V delegate() calc) {
		auto found = key in cache;

		if (found is null) {
			found = insert(key, calc());
			while (cache.length > N) {
				popFront();
			}
			return found.value;
		}

		moveBack(found);
		return found.value;
	}
}
unittest {
	QueueCache!(int,int,4) a;
	assert(a.cacheOrder.length == 0);
	a.fetch(1, () => 1);
	assert(a.cacheOrder.length == 1);
	assert(a.cacheOrder[0].key == 1);
	assert(a.cacheOrder[0].value == 1);
	a.fetch(1, () => 2);
	assert(a.cacheOrder.length == 1);
	assert(a.cacheOrder[0].key == 1);
	assert(a.cacheOrder[0].value == 1);
	a.fetch(2, () => 3);
	assert(a.cacheOrder.length == 2);
	assert(a.cacheOrder[0].key == 1);
	assert(a.cacheOrder[0].value == 1);
	assert(a.cacheOrder[1].key == 2);
	assert(a.cacheOrder[1].value == 3);
	a.fetch(3, () => 4);
	assert(a.cacheOrder.length == 3);
	assert(a.cacheOrder[0].key == 1);
	assert(a.cacheOrder[0].value == 1);
	assert(a.cacheOrder[1].key == 2);
	assert(a.cacheOrder[1].value == 3);
	assert(a.cacheOrder[2].key == 3);
	assert(a.cacheOrder[2].value == 4);
	a.fetch(4, () => 5);
	assert(a.cacheOrder.length == 4);
	assert(a.cacheOrder[0].key == 1);
	assert(a.cacheOrder[0].value == 1);
	assert(a.cacheOrder[1].key == 2);
	assert(a.cacheOrder[1].value == 3);
	assert(a.cacheOrder[2].key == 3);
	assert(a.cacheOrder[2].value == 4);
	assert(a.cacheOrder[3].key == 4);
	assert(a.cacheOrder[3].value == 5);
	a.fetch(2, () => 0);
	assert(a.cacheOrder.length == 4);
	assert(a.cacheOrder[0].key == 1);
	assert(a.cacheOrder[0].value == 1);
	assert(a.cacheOrder[1].key == 3);
	assert(a.cacheOrder[1].value == 4);
	assert(a.cacheOrder[2].key == 4);
	assert(a.cacheOrder[2].value == 5);
	assert(a.cacheOrder[3].key == 2);
	assert(a.cacheOrder[3].value == 3);
	a.fetch(5, () => 6);
	assert(a.cacheOrder.length == 4);
	assert(a.cacheOrder[0].key == 3);
	assert(a.cacheOrder[0].value == 4);
	assert(a.cacheOrder[1].key == 4);
	assert(a.cacheOrder[1].value == 5);
	assert(a.cacheOrder[2].key == 2);
	assert(a.cacheOrder[2].value == 3);
	assert(a.cacheOrder[3].key == 5);
	assert(a.cacheOrder[3].value == 6);
}