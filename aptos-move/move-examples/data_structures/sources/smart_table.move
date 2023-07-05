/// A smart table implementation based on linear hashing. (https://en.wikipedia.org/wiki/Linear_hashing)
/// Compare to Table, it uses less storage slots but has higher chance of collision, it's a trade-off between space and time.
/// Compare to other implementation, linear hashing splits one bucket a time instead of doubling buckets when expanding to avoid unexpected gas cost.
/// SmartTable uses faster hash function SipHash instead of cryptographically secure hash functions like sha3-256 since it tolerates collisions.
module aptos_std::smart_table2 {
    use std::error;
    use std::vector;
    use aptos_std::aptos_hash::sip_hash_from_value;
    use aptos_std::table_with_length::{Self, TableWithLength};
    use aptos_std::type_info::size_of_val;
    use aptos_std::math64::max;

    /// Key not found in the smart table
    const ENOT_FOUND: u64 = 1;
    /// Smart table capacity must be larger than 0
    const EZERO_CAPACITY: u64 = 2;
    /// Cannot destroy non-empty hashmap
    const ENOT_EMPTY: u64 = 3;
    /// Key already exists
    const EALREADY_EXIST: u64 = 4;
    /// Invalid load threshold percent to trigger split.
    const EINVALID_LOAD_THRESHOLD_PERCENT: u64 = 5;
    /// Invalid target bucket size.
    const EINVALID_TARGET_BUCKET_SIZE: u64 = 6;

    /// SmartTable entry contains both the key and value.
    struct Entry<K, V> has copy, drop, store {
        hash: u64,
        key: K,
        value: V,
    }

    struct SmartTable<K, V> has store {
        buckets: TableWithLength<u64, vector<Entry<K, V>>>,
        num_buckets: u64,
        // number of bits to represent num_buckets
        level: u8,
        // total number of items
        size: u64,
        // Split will be triggered when target load threshold in percentage is reached when adding a new entry.
        split_load_threshold: u8,
        // The target size of each bucket, which is NOT enforced so oversized buckets can exist.
        target_bucket_size: u64,
    }

    /// Create an empty SmartTable with default configurations.
    public fun new<K: copy + drop + store, V: store>(): SmartTable<K, V> {
        new_with_config<K, V>(0, 0, 0)
    }

    /// Create an empty SmartTable with customized configurations.
    /// `num_initial_buckets`: The number of buckets on initialization. 0 means using default value.
    /// `split_load_threshold`: The percent number which once reached, split will be triggered. 0 means using default
    /// value.
    /// `target_bucket_size`: The target number of entries per bucket, though not guaranteed. 0 means not set and will
    /// dynamically assgined by the contract code.
    public fun new_with_config<K: copy + drop + store, V: store>(num_initial_buckets: u64, split_load_threshold: u8, target_bucket_size: u64): SmartTable<K, V> {
        assert!(split_load_threshold <= 100, error::invalid_argument(EINVALID_LOAD_THRESHOLD_PERCENT));
        let buckets = table_with_length::new();
        table_with_length::add(&mut buckets, 0, vector::empty());
        let table = SmartTable {
            buckets,
            num_buckets: 1,
            level: 0,
            size: 0,
            // The default split load threshold is 75%.
            split_load_threshold: if (split_load_threshold == 0) {75} else {split_load_threshold},
            target_bucket_size,
        };
        // The default number of initial buckets is 2.
        if (num_initial_buckets == 0) {
            num_initial_buckets = 2;
        };
        while (num_initial_buckets > 1) {
            num_initial_buckets = num_initial_buckets - 1;
            split_one_bucket(&mut table);
        };
        table
    }

    /// Destroy empty table.
    /// Aborts if it's not empty.
    public fun destroy_empty<K, V>(table: SmartTable<K, V>) {
        assert!(table.size == 0, error::invalid_argument(ENOT_EMPTY));
        let i = 0;
        while (i < table.num_buckets) {
            vector::destroy_empty(table_with_length::remove(&mut table.buckets, i));
            i = i + 1;
        };
        let SmartTable {buckets, num_buckets: _, level: _, size: _, split_load_threshold:_, target_bucket_size: _} = table;
        table_with_length::destroy_empty(buckets);
    }

    /// Destroy a table completely when V is dropable.
    public fun destroy<K: drop, V: drop>(table: SmartTable<K, V>) {
        let i = 0;
        while (i < table.num_buckets) {
            table_with_length::remove(&mut table.buckets, i);
            i = i + 1;
        };
        let SmartTable {buckets, num_buckets: _, level: _, size: _, split_load_threshold:_, target_bucket_size: _} = table;
        table_with_length::destroy_empty(buckets);
    }

    /// Add (key, value) pair in the hash map, it may grow one bucket if current load factor exceeds the threshold.
    /// Note it may not split the actual overflowed bucket. Instead, it was determined by `num_buckets` and `level`.
    /// For standard linear hash algorithm, it is stored as a variable but `num_buckets` here could be leveraged.
    /// Abort if `key` already exists.
    /// Note: This method may occasionally cost much more gas when triggering bucket split.
    public fun add<K, V>(table: &mut SmartTable<K, V>, key: K, value: V) {
        let hash = sip_hash_from_value(&key);
        let index = bucket_index(table.level, table.num_buckets, hash);
        let bucket = table_with_length::borrow_mut(&mut table.buckets, index);
        vector::for_each_ref(bucket, |entry| {
            let e: &Entry<K, V> = entry;
            assert!(&e.key != &key, error::invalid_argument(EALREADY_EXIST));
        });
        let e = Entry {hash, key, value};
        if (table.target_bucket_size == 0) {
            let estimated_entry_size = max(size_of_val(&e), 1);
            table.target_bucket_size = max(1024 /* free_write_quota */ / estimated_entry_size, 1);
        };
        vector::push_back(bucket, e);
        table.size = table.size + 1;

        if (load_factor(table) >= (table.split_load_threshold as u64)) {
            split_one_bucket(table);
        }
    }

    /// Decide which is the next bucket to split and split it into two with the elements inside the bucket.
    fun split_one_bucket<K, V>(table: &mut SmartTable<K, V>) {
        let new_bucket_index = table.num_buckets;
        // the next bucket to split is num_bucket without the most significant bit.
        let to_split = new_bucket_index ^ (1 << table.level);
        let new_bucket = vector::empty();
        table.num_buckets = new_bucket_index + 1;
        // if the whole level is splitted once, bump the level.
        if (to_split + 1 == 1 << table.level) {
            table.level = table.level + 1;
        };
        let old_bucket = table_with_length::borrow_mut(&mut table.buckets, to_split);
        // partition the bucket. after the loop, i == j and [0..i) stays in old bucket, [j..len) goes to new bucket
        let i = 0;
        let j = vector::length(old_bucket);
        let len = j;
        while (i < j) {
            let entry = vector::borrow(old_bucket, i);
            let index = bucket_index(table.level, table.num_buckets, entry.hash);
            if (index == new_bucket_index) {
                j = j - 1;
                vector::swap(old_bucket, i, j);
            } else {
                i = i + 1;
            };
        };
        while (j < len) {
            let entry = vector::pop_back(old_bucket);
            vector::push_back(&mut new_bucket, entry);
            len = len - 1;
        };
        table_with_length::add(&mut table.buckets, new_bucket_index, new_bucket);
    }

    /// Return the expected bucket index to find the hash.
    /// Basically, it use different base `1 << level` vs `1 << (level + 1)` in modulo operation based on the target
    /// bucket index compared to the index of the next bucket to split.
    fun bucket_index(level: u8, num_buckets: u64, hash: u64): u64 {
        let index = hash % (1 << (level + 1));
        if (index < num_buckets) {
            // in existing bucket
            index
        } else {
            // in unsplitted bucket
            index % (1 << level)
        }
    }

    /// Acquire an immutable reference to the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun borrow<K: drop, V>(table: &SmartTable<K, V>, key: K): &V {
        let index = bucket_index(table.level, table.num_buckets, sip_hash_from_value(&key));
        let bucket = table_with_length::borrow(&table.buckets, index);
        let i = 0;
        let len = vector::length(bucket);
        while (i < len) {
            let entry = vector::borrow(bucket, i);
            if (&entry.key == &key) {
                return &entry.value
            };
            i = i + 1;
        };
        abort error::invalid_argument(ENOT_FOUND)
    }

    /// Acquire an immutable reference to the value which `key` maps to.
    /// Returns specified default value if there is no entry for `key`.
    public fun borrow_with_default<K: copy + drop, V>(table: &SmartTable<K, V>, key: K, default: &V): &V {
        if (!contains(table, copy key)) {
            default
        } else {
            borrow(table, copy key)
        }
    }

    /// Acquire a mutable reference to the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun borrow_mut<K: drop, V>(table: &mut SmartTable<K, V>, key: K): &mut V {
        let index = bucket_index(table.level, table.num_buckets, sip_hash_from_value(&key));
        let bucket = table_with_length::borrow_mut(&mut table.buckets, index);
        let i = 0;
        let len = vector::length(bucket);
        while (i < len) {
            let entry = vector::borrow_mut(bucket, i);
            if (&entry.key == &key) {
                return &mut entry.value
            };
            i = i + 1;
        };
        abort error::invalid_argument(ENOT_FOUND)
    }

    /// Acquire a mutable reference to the value which `key` maps to.
    /// Insert the pair (`key`, `default`) first if there is no entry for `key`.
    public fun borrow_mut_with_default<K: copy + drop, V: drop>(table: &mut SmartTable<K, V>, key: K, default: V): &mut V {
        if (!contains(table, copy key)) {
            add(table, copy key, default)
        };
        borrow_mut(table, key)
    }

    /// Returns true iff `table` contains an entry for `key`.
    public fun contains<K: drop, V>(table: &SmartTable<K, V>, key: K): bool {
        let hash = sip_hash_from_value(&key);
        let index = bucket_index(table.level, table.num_buckets, hash);
        let bucket = table_with_length::borrow(&table.buckets, index);
        vector::any(bucket, |entry| {
            let e: &Entry<K, V> = entry;
            e.hash == hash && &e.key == &key
        })
    }

    /// Remove from `table` and return the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun remove<K: copy + drop, V>(table: &mut SmartTable<K, V>, key: K): V {
        let index = bucket_index(table.level, table.num_buckets, sip_hash_from_value(&key));
        let bucket = table_with_length::borrow_mut(&mut table.buckets, index);
        let i = 0;
        let len = vector::length(bucket);
        while (i < len) {
            let entry = vector::borrow(bucket, i);
            if (&entry.key == &key) {
                let Entry {hash:_, key:_, value} = vector::swap_remove(bucket, i);
                table.size = table.size - 1;
                return value
            };
            i = i + 1;
        };
        abort error::invalid_argument(ENOT_FOUND)
    }

    /// Insert the pair (`key`, `value`) if there is no entry for `key`.
    /// update the value of the entry for `key` to `value` otherwise
    public fun upsert<K: copy + drop, V: drop>(table: &mut SmartTable<K, V>, key: K, value: V) {
        if (!contains(table, copy key)) {
            add(table, copy key, value)
        } else {
            let ref = borrow_mut(table, key);
            *ref = value;
        };
    }

    /// Returns the length of the table, i.e. the number of entries.
    public fun length<K, V>(table: &SmartTable<K, V>): u64 {
        table.size
    }


    /// Apply the function to each key-value pair in the table, consuming it.
    public inline fun for_each<K: copy + drop, V>(table: SmartTable<K, V>, f: |K, V|) {
        let SmartTable {buckets, num_buckets, level: _, size: _, split_load_threshold:_, target_bucket_size: _} = table;
        let i = 0;
        while (i < num_buckets) {
            vector::for_each(table_with_length::remove(&mut buckets, i), |elem| {
                let Entry {hash: _, key, value} = elem;
                f(key, value)
            });
            i = i + 1;
        };
        table_with_length::destroy_empty(buckets);
    }

    /// Apply the function to a reference of each key-value pair in the table.
    public inline fun for_each_ref<K, V>(table: &SmartTable<K, V>, f: |&K, &V|) {
        let i = 0;
        while (i < table.num_buckets) {
            vector::for_each_ref(table_with_length::borrow(&table.buckets, i), |elem| {
                let e: &Entry<K, V> = elem;
                f(&e.key, &e.value)
            });
            i = i + 1;
        }
    }

    /// Apply the function to a reference of each key-value pair in the table.
    public inline fun for_each_mut<K, V>(table: &mut SmartTable<K, V>, f: |&K, &mut V|) {
        let i = 0;
        while (i < table.num_buckets) {
            vector::for_each_mut(table_with_length::borrow_mut(&mut table.buckets, i), |elem| {
                let e: &mut Entry<K, V> = elem;
                f(&e.key, &mut e.value)
            });
            i = i + 1;
        };
    }

    /// Fold the function over the key-value pairs of the table.
    public inline fun fold<A, K: copy + drop, V>(
        table: SmartTable<K, V>,
        init: A,
        f: |A,K,V|A
    ): A {
        for_each(table, |key, value| init = f(init, key, value));
        init
    }

    /// Map the function over the key-value pairs of the table.
    public inline fun map<K: copy + drop + store, V1, V2: store>(
        table: SmartTable<K, V1>,
        f: |V1|V2
    ): SmartTable<K, V2> {
        let new_table = new_with_config<K, V2>(0, table.split_load_threshold, 0);
        for_each(table, |key, value| add(&mut new_table, key, f(value)));
        new_table
    }

    /// Map the function over the references of key-value pairs in the table without modifying it.
    public inline fun map_ref<K: copy + drop + store, V1, V2: store>(
        table: &SmartTable<K, V1>,
        f: |&V1|V2
    ): SmartTable<K, V2> {
        let new_table = new_with_config<K, V2>(0, table.split_load_threshold, 0);
        for_each_ref(table, |key, value| add(&mut new_table, *key, f(value)));
        new_table
    }

    /// Filter entries in the table.
    public inline fun filter<K: copy + drop + store, V: store>(
        table: SmartTable<K, V>,
        p: |&V|bool
    ): SmartTable<K, V> {
        let new_table = new_with_config<K, V>(table.num_buckets, table.split_load_threshold, table.target_bucket_size);
        for_each(table, |key, value| {
            if (p(&value)) {
                add(&mut new_table, key, value);
            }
        });
        new_table
}

    /// Return true if any key-value pair in the table satisfies the predicate.
    public inline fun any<K, V>(
        table: &SmartTable<K, V>,
        p: |&K, &V|bool
    ): bool {
        let found = false;
        let i = 0;
        while (i < table.num_buckets) {
            found = vector::any(table_with_length::borrow(&table.buckets, i), |elem| {
                let e: &Entry<K, V> = elem;
                p(&e.key, &e.value)
            });
            if (found) break;
            i = i + 1;
        };
        found
    }

    /// Return true if all key-value pairs in the table satisfies the predicate.
    public inline fun all<K, V>(
        table: &SmartTable<K, V>,
        p: |&K, &V|bool
    ): bool {
        let result = true;
        let i = 0;
        while (i < table.num_buckets) {
            let bucket = table_with_length::borrow(&table.buckets, i);
            let j = 0;
            let bucket_len = vector::length(bucket);
            while (j < bucket_len) {
                let e= vector::borrow(bucket, j);
                if (!p(&e.key, &e.value)) {
                    result = false;
                    break
                };
                j = j + 1;
            };
            i = i + 1;
        };
        result
    }

    /// Return the load factor of the hashtable.
    public fun load_factor<K, V>(table: &SmartTable<K, V>): u64 {
        table.size * 100 / table.num_buckets / table.target_bucket_size
    }

    /// Update `split_load_threshold`.
    public fun update_split_load_threshold<K, V>(table: &mut SmartTable<K, V>, split_load_threshold: u8) {
        assert!(split_load_threshold <= 100 && split_load_threshold > 0, error::invalid_argument(EINVALID_LOAD_THRESHOLD_PERCENT));
        table.split_load_threshold = split_load_threshold;
    }

    /// Update `target_bucket_size`.
    public fun update_target_bucket_size<K, V>(table: &mut SmartTable<K, V>, target_bucket_size: u64) {
        assert!(target_bucket_size > 0, error::invalid_argument(EINVALID_TARGET_BUCKET_SIZE));
        table.target_bucket_size = target_bucket_size;
    }

    #[test]
    fun smart_table_test() {
        let table = new();
        let i = 0;
        while (i < 200) {
            add(&mut table, i, i);
            i = i + 1;
        };
        assert!(length(&table) == 200, 0);
        i = 0;
        while (i < 200) {
            *borrow_mut(&mut table, i) = i * 2;
            assert!(*borrow(&table, i) == i * 2, 0);
            i = i + 1;
        };
        i = 0;
        assert!(table.num_buckets > 5, table.num_buckets);
        while (i < 200) {
            assert!(contains(&table, i), 0);
            assert!(remove(&mut table, i) == i * 2, 0);
            i = i + 1;
        };
        destroy_empty(table);
    }

    #[test]
    fun smart_table_split_test() {
        let table: SmartTable<u64, u64> = new_with_config(1, 100, 1);
        let i = 1;
        let level = 0;
        while (i <= 256) {
            assert!(table.num_buckets == i, 0);
            assert!(table.level == level, i);
            add(&mut table, i, i);
            i = i + 1;
            if (i == 1 << (level + 1)) {
                level = level + 1;
            };
        };
        let i = 1;
        while (i <= 256) {
            assert!(*borrow(&table, i) == i, 0);
            i = i + 1;
        };
        assert!(table.num_buckets == 257, table.num_buckets);
        assert!(load_factor(&table) == 99, 0);
        assert!(length(&table) == 256, 0);
        destroy(table);
    }

    #[test]
    fun smart_table_update_configs() {
        let table = new();
        let i = 0;
        while (i < 200) {
            add(&mut table, i, i);
            i = i + 1;
        };
        assert!(length(&table) == 200, 0);
        update_target_bucket_size(&mut table, 10);
        update_split_load_threshold(&mut table, 50);
        while (i < 400) {
            add(&mut table, i, i);
            i = i + 1;
        };
        assert!(length(&table) == 400, 0);
        i = 0;
        while (i < 400) {
            assert!(contains(&table, i), 0);
            assert!(remove(&mut table, i) == i, 0);
            i = i + 1;
        };
        destroy_empty(table);
    }

    #[test_only]
    fun make(): SmartTable<u64, u64> {
        let table = new_with_config<u64, u64>(0, 50, 10);
        let i = 0u64;
        while (i < 100) {
            add(&mut table, i, i);
            i = i + 1;
        };
        table
    }

    #[test]
    fun test_for_each() {
        let t = make();
        let s = 0;
        for_each(t, |x, y| {
            s = s + x + y;
        });
        assert!(s == 9900, 0)
    }

    #[test]
    fun test_for_each_ref() {
        let t = make();
        let s = 0;
        for_each_ref(&t, |x, y| {
            s = s + *x + *y;
        });
        assert!(s == 9900, 0);
        destroy(t);
    }

    #[test]
    fun test_for_each_mut() {
        let t = make();
        for_each_mut(&mut t, |_key, val| {
            let val : &mut u64 = val;
            *val = *val + 1
        });
        for_each_ref(&t, |key, val| {
            assert!(*key + 1 == *val, *key);
        });
        destroy(t);
    }

    #[test]
    fun test_fold() {
        let t = make();
        let r = fold(t, 1, |accu, key, val| {
            accu + key + val
        });
        assert!(r == 9901, 0);
    }

    #[test]
    fun test_map() {
        let t = make();
        let r = map(t, |val| val + 1);
        for_each_ref(&r, |key, val| {
            assert!(*key + 1 == *val, *key);
        });
        destroy(r);
    }

    #[test]
    fun test_map_ref() {
        let t = make();
        let r = map_ref(&t, |val| *val + 1);
        for_each_ref(&r, |key, val| {
            assert!(*key + 1 == *val, *key);
        });
        destroy(t);
        destroy(r);
    }

    #[test]
    fun test_filter() {
        let t = make();
        let r = filter(t, |val| *val < 50);
        assert!(length(&r) == 50, 0);
        assert!(
            fold(r, 0, |accu, _key, val| {
                accu + val
            }) == 1225, 1);
    }
    #[test]
    fun test_any() {
        let t = make();
        let r = any(&t, |_k, v| *v >= 99);
        assert!(r, 0);
        destroy(t);
    }

    #[test]
    fun test_all() {
        let t = make();
        let r = all(&t, |_k, v| *v < 100);
        assert!(r, 0);
        destroy(t);
    }
}
