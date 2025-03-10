module movecraft::block {
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::aptos_account;
    use aptos_framework::event;
    use aptos_framework::object::{Self, ConstructorRef, Object, ObjectCore};
    use aptos_framework::timestamp;
    use aptos_std::string_utils::{Self};
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_token_objects::collection;
    use aptos_token_objects::token;
    use aptos_token_objects::property_map;
    use std::option;
    use std::signer::address_of;
    use std::signer;
    use std::string::{Self, String};
    // randomness: TODO: maybe works in the future
    // use aptos_framework::randomness; 

    // coin
    use aptos_framework::coin::Coin;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;

    // vector
    use std::vector;

    use movecraft::block_type;

    /// Movecraft error codes
    const ENOT_SIGNER_NOT_PRICE_CAP_OWNER: u64 = 0;
    const ENOT_VALID_BLOCK_TYPE: u64 = 2;
    const ENOT_BLOCK_OWNER: u64 = 3;
    const ENOT_VALID_BLOCK: u64 = 4;
    const ENOT_STACKABLE: u64 = 5;
    const ENOT_TYPEMATCH: u64 = 6;
    const ENOT_AMOUNT_MATCH: u64= 7;

    /// Movecraft constants
    const STATE_SEED: vector<u8> = b"movecraft_signer";
    const MINT_SEED: vector<u8> = b"mint_signer";
    const BURN_SEED: vector<u8> = b"burn_signer";

    const BLOCK_COLLECTION_NAME: vector<u8> = b"Blocks";
    const BLOCK_COLLECTION_DESCRIPTION: vector<u8> = b"Movecraft Blocks";

    const BLOCK_COLLECTION_URI: vector<u8> = b"https://arweave.net/-pzxECD-3v184ePZWmPNhR2y0Ikht7jFpmL9lK_cHs0";

    const LOG_BLOCK_TYPE: u64 = 11;
    const PLANK_BLOCK_TYPE: u64 = 12;

    const BLOCK_ID_KEY: vector<u8> = b"id";
    const BLOCK_TYPE_KEY: vector<u8> = b"type";
    const BLOCK_COUNT_KEY: vector<u8> = b"count";

    // TODO:The mint price could be set by the smart contract owner.

    struct PriceCap has key {}

    /// Global state
    struct State has key {
        // the signer cap of the module's resource account
        signer_cap: SignerCapability,
        price_cap_id: address,
        last_block_id: u64, 
        mint_price: u64,
        // block address collection
        blocks: SimpleMap<u64, address>,
        acc_mint_block_num: SimpleMap<u64, u64>, 

        // events
        mint_block_events: event::EventHandle<MintBlockEvents>,
        burn_block_events: event::EventHandle<BurnBlockEvents>,
        stack_block_events: event::EventHandle<StackBlockEvents>,
    }

    struct Block has key {
        block_type: u64, 
        block_num: u64, 
        mutator_ref: token::MutatorRef,
        burn_ref: token::BurnRef,        
        property_mutator_ref: property_map::MutatorRef,        
    }

    struct Treature has key{
        coins: Coin<AptosCoin>
    }
    
    // Movecraft events
    struct MintBlockEvents has drop, store {
        name: String,
        block_id: u64,
        creator: address,
        event_timestamp: u64
    }

    struct BurnBlockEvents has drop, store {
        name: String,
        block_id: u64,
        owner: address,
        event_timestamp: u64
    }

    struct StackBlockEvents has drop, store {
        block_id: u64,
        other_block_id: u64,
        owner: address,
        event_timestamp: u64
    }

    fun transfer<T: key>(owner: &signer, object: Object<T>, destination: address) {
        object::transfer(owner, object, destination);
    }

    // This function is only callable during publishing
    fun init_module(account: &signer) {
        let (resource_account, signer_cap) = account::create_resource_account(account, STATE_SEED);

        move_to(
            account, 
            Treature {
                coins: coin::zero()
            }
        );

        // Ref: https://aptos.dev/en/build/smart-contracts/objects
        let caller_address = signer::address_of(account);
        let constructor_ref = object::create_object(caller_address);
        let object_signer = object::generate_signer(&constructor_ref);
        move_to(&object_signer, PriceCap {});
        let object = object::object_from_constructor_ref<ObjectCore>(&constructor_ref);
        
        // Get the object ID (address) of the PriceCap object
        let price_cap_id = object::object_address(&object);

        object::transfer(account, object, @admin);

        move_to(&resource_account, State {
            signer_cap,
            price_cap_id, // Use the object ID here
            last_block_id: 0,
            acc_mint_block_num: simple_map::create(),
            blocks: simple_map::create(),
            mint_block_events: account::new_event_handle<MintBlockEvents>(&resource_account),
            burn_block_events: account::new_event_handle<BurnBlockEvents>(&resource_account),
            stack_block_events: account::new_event_handle<StackBlockEvents>(&resource_account),
            mint_price: 1_000_000, // Set an initial price, adjust as needed
        });

        // Create log and plank collection to the resource account
        collection::create_unlimited_collection(
            &resource_account,
            string::utf8(BLOCK_COLLECTION_DESCRIPTION),
            string::utf8(BLOCK_COLLECTION_NAME),
            option::none(),
            string::utf8(BLOCK_COLLECTION_URI),
        );
    }

    // Set mint price by admin: the Cap Object Owner
    // TODO: delete the object parameter
    public entry fun set_mint_price(caller: &signer, new_price: u64) acquires State {
        // Check if the caller is the owner of the PriceCap object
        assert!(exists<PriceCap>(signer::address_of(caller)), ENOT_SIGNER_NOT_PRICE_CAP_OWNER);
        let object = object::address_to_object<PriceCap>(signer::address_of(caller));
        
        let resource_address = get_resource_address();
        let state = borrow_global_mut<State>(resource_address);
        state.mint_price = new_price;
    }

    // Mint block by randomlly type
    public entry fun mint_to(creator: &signer, to: address) acquires State {
        // Pay for block
        // coin::transfer<AptosCoin>(creator, @movecraft, get_mint_price());

        // Use timestamp for randomness
        let type = timestamp::now_microseconds() % 22;
        let block_type: u64;

        if(type >= 0 && type <= 3) {
            // 4/22 probability for this type.
            block_type = 0;
        } else if(type > 3 && type <= 6) {
            // 4 types of blocks: 3/22 probability each.
            block_type = 1;
        } else if(type > 6 && type <= 9) {
            block_type = 2;
        } else if(type > 9 && type <= 12) {
            block_type = 3;
        } else if(type > 12 && type <= 15) {
            block_type = 4;
        } else if(type > 15 && type <= 18) {
            block_type = 5;
        } else if(type > 18 && type <= 20) {
            // 1/11 chance to get this block
            block_type = 6;
        } else {
            // 1/22 chance to get this block
            block_type = 7;
        };

        let block_type_name = string::utf8(block_type::name(block_type));

        let resource_address = get_resource_address();
        let state = borrow_global_mut<State>(resource_address);
        let resource_account = account::create_signer_with_capability(&state.signer_cap);

        let block_id = state.last_block_id + 1;
        let token_name = string_utils::format2(&b"{} #{}", block_type_name, block_id);

        let description = string::utf8(block_type::description(block_type));
        let uri = string::utf8(block_type::uri(block_type));

        let constructor_ref = token::create_named_token(
            &resource_account,
            string::utf8(BLOCK_COLLECTION_NAME),
            description,
            token_name,
            option::none(),
            uri,
        );

        // Generate mint, burn, transfer cap
        let token_signer = object::generate_signer(&constructor_ref);
        let mutator_ref = token::generate_mutator_ref(&constructor_ref);
        let burn_ref = token::generate_burn_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        let property_mutator_ref = property_map::generate_mutator_ref(&constructor_ref);

        let properties = property_map::prepare_input(vector[], vector[], vector[]);
        property_map::init(&constructor_ref, properties);
        property_map::add_typed<u64>(
            &property_mutator_ref,
            string::utf8(BLOCK_ID_KEY),
            block_id,
        );
        property_map::add_typed<u64>(
            &property_mutator_ref,
            string::utf8(BLOCK_TYPE_KEY),
            block_type,
            // block type here.
        );
        property_map::add_typed<u64>(
            &property_mutator_ref,
            string::utf8(BLOCK_COUNT_KEY),
            1,
        );

        let block_num = 1;
        // Move block object into token signer
        let block = Block {
            block_type, 
            block_num, 
            mutator_ref,
            burn_ref,
            property_mutator_ref,
        };

        move_to(&token_signer, block);

        // Move token to 'to'
        object::transfer_with_ref(object::generate_linear_transfer_ref(&transfer_ref), to);

        // Update last block id
        let block_address = signer::address_of(&token_signer);
        simple_map::add(&mut state.blocks, block_id, block_address);
        state.last_block_id = block_id;

        // Update acc mint block num
        if (simple_map::contains_key(&state.acc_mint_block_num, &block_type)) {
            let current_count = *simple_map::borrow(&state.acc_mint_block_num, &block_type);
            simple_map::upsert(&mut state.acc_mint_block_num, block_type, current_count + 1);
        } else {
            simple_map::add(&mut state.acc_mint_block_num, block_type, 1);
        };

        // Emit mint event
        event::emit_event<MintBlockEvents>(
            &mut state.mint_block_events,
            MintBlockEvents {
                name: token_name,
                block_id,
                creator: to,
                event_timestamp: timestamp::now_seconds(),
            },
        );
    }

    // Mint block by randomlly type
    #[randomness]
    entry fun mint(creator: &signer) acquires State {
        mint_to(creator, signer::address_of(creator))
    }

    #[randomness]
    entry fun mint_to_address(creator: &signer, to: address) acquires State {
        mint_to(creator, to)
    }
    

    // Burn block by owner
    public entry fun burn_block(owner: &signer, block_id: u64) acquires State, Block {
        
        let resource_address = get_resource_address();
        let state = borrow_global_mut<State>(resource_address);

        // Get block address
        let owner_address = signer::address_of(owner);
        let block_address = get_block_address(&state.blocks, owner_address, block_id);
        let block_token_object = object::address_to_object<Block>(block_address);
        let name = token::name(block_token_object);

        let block = move_from<Block>(block_address);
        let Block {
            block_type: _, 
            block_num: _, 
            burn_ref,
            mutator_ref: _,
            property_mutator_ref: _,
        } = block;

        // Emit burn event
        event::emit_event<BurnBlockEvents>(
            &mut state.burn_block_events,
            BurnBlockEvents {
                name,
                block_id,
                owner: owner_address,
                event_timestamp: timestamp::now_seconds(),
            },
        );

        // Burn token
        token::burn(burn_ref);
        simple_map::remove(&mut state.blocks, &block_id);
    }

    // Stack by owned blocks
    public entry fun stack_block(owner: &signer, block_1_id: u64, block_2_id: u64) acquires State, Block {
        
        let resource_address = get_resource_address();
        let state = borrow_global_mut<State>(resource_address);
        let owner_address = signer::address_of(owner);

        // Validate block stackable
        let block2_address = get_block_address(&state.blocks, owner_address, block_2_id);
        let (_block2_id, _block2_name, block2_type, block2_count, block2_stackable) = get_block_properties(block2_address);
        assert!(block2_stackable, ENOT_STACKABLE);

        let block1_address = get_block_address(&state.blocks, owner_address, block_1_id);
        let (_block1_id, _block1_name, block1_type, block1_count, block1_stackable) = get_block_properties(block1_address);
        assert!(block1_stackable, ENOT_STACKABLE);

        assert!(block1_type == block2_type, ENOT_TYPEMATCH);

        // Update Block count
        let block = borrow_global_mut<Block>(block1_address);
        // 1. Update block Property
        property_map::update_typed<u64>(&mut block.property_mutator_ref, &string::utf8(BLOCK_COUNT_KEY), block1_count + block2_count);
        // 2. Update block_num in obj
        block.block_num = block1_count + block2_count;

        // Emit stack event
        event::emit_event<StackBlockEvents>(
            &mut state.stack_block_events,
            StackBlockEvents {
                block_id: block_1_id,
                other_block_id: block_2_id,
                owner: owner_address,
                event_timestamp: timestamp::now_seconds(),
            },
        );

        // Burn block 2
        burn_block(owner, block_2_id);
    }

    fun get_block_address(blocks: &SimpleMap<u64, address>, owner_address: address, block_id: u64): address {
        assert!(simple_map::contains_key(blocks, &block_id), ENOT_VALID_BLOCK);
        let block_address = *simple_map::borrow(blocks, &block_id);

        let block_token_obj = object::address_to_object<token::Token>(block_address);
        let token_owner_address = object::owner(block_token_obj);
        assert!(owner_address == token_owner_address, ENOT_BLOCK_OWNER);

        block_address
    }

    fun get_block_properties(block_address: address): (u64, String, u64, u64, bool) {
        let block_token_object = object::address_to_object<Block>(block_address);

        let name = token::name(block_token_object);
        let type = property_map::read_u64(&block_token_object, &string::utf8(BLOCK_TYPE_KEY));
        let count = property_map::read_u64(&block_token_object, &string::utf8(BLOCK_COUNT_KEY));
        let id = property_map::read_u64(&block_token_object, &string::utf8(BLOCK_ID_KEY));
        let stackable = block_type::is_stackable(type);
        (id, name, type, count, stackable)
    }


    // Viewer functions

    #[view]
    public fun get_collection_address(): address {
        let resource_address = get_resource_address();
        collection::create_collection_address(&resource_address, &string::utf8(BLOCK_COLLECTION_NAME))
    }

    #[view]
    public fun get_resource_address(): address {
        account::create_resource_address(&@movecraft, STATE_SEED)
    }

    // get Cap Object Id
    #[view]
    public fun get_price_cap_object_id(): address acquires State {
        let resource_address = get_resource_address();
        let state = borrow_global<State>(resource_address);
        state.price_cap_id
    }

    // get all the cell minted.
    #[view]
    public fun get_all_minted_blocks(): (vector<u64>, vector<u64>) acquires State {
        let resource_address = get_resource_address();
        let state = borrow_global<State>(resource_address);
        let (block_types, block_counts) = simple_map::to_vec_pair(state.acc_mint_block_num);
        (block_types, block_counts)
    }

    #[view]
    public fun get_mint_price(): u64 acquires State {
        let resource_address = get_resource_address();
        let state = borrow_global<State>(resource_address);
        state.mint_price
    }
    
    #[view]
    public fun get_block_properties_by_obj(block: Object<Block>): (u64, String, u64, u64, bool) {
        let name = token::name(block);
        let type = property_map::read_u64(&block, &string::utf8(BLOCK_TYPE_KEY));
        let count = property_map::read_u64(&block, &string::utf8(BLOCK_COUNT_KEY));
        let id = property_map::read_u64(&block, &string::utf8(BLOCK_ID_KEY));
        let stackable = block_type::is_stackable(type);
        (id, name, type, count, stackable)
    }

    // ==== TESTS ====
    // Setup testing environment
    #[test_only]
    use aptos_framework::account::create_account_for_test;

    #[test_only]
    fun setup_test(aptos: &signer, account: &signer, creator: &signer){
        // create a fake account (only for testing purposes)
        create_account_for_test(signer::address_of(creator));
        create_account_for_test(signer::address_of(account));

        timestamp::set_time_has_started_for_testing(aptos);
        init_module(account);
    }

    // Test creating an Log & plank block
    #[test(aptos = @0x1, account = @movecraft, creator = @0x123)]
    fun test_mint_block(aptos: &signer, account: &signer, creator: &signer) acquires State {
        setup_test(aptos, account, creator);

        mint_by_type(creator, LOG_BLOCK_TYPE);
        mint_by_type(creator, LOG_BLOCK_TYPE);
        mint_by_type(creator, LOG_BLOCK_TYPE);

        mint_by_type(creator, PLANK_BLOCK_TYPE);
        mint_by_type(creator, PLANK_BLOCK_TYPE);
    }

    // Test burn block
    #[test(aptos = @0x1, account = @movecraft, creator = @0x123)]
    fun test_burn_block(aptos: &signer, account: &signer, creator: &signer) acquires State, Block {
        setup_test(aptos, account, creator);

        mint_by_type(creator, LOG_BLOCK_TYPE);
        burn_block(creator, 1);
    }

    // Test burn block failed
    #[test(aptos = @0x1, account = @movecraft, creator = @0x123)]
    #[expected_failure(abort_code = ENOT_VALID_BLOCK, location = Self)]
    fun test_burn_block_failed_invalid_block(aptos: &signer, account: &signer, creator: &signer) acquires State, Block {
        setup_test(aptos, account, creator);

        mint_by_type(creator, LOG_BLOCK_TYPE);
        burn_block(creator, 1);

        // Not able to burn block again
        burn_block(creator, 1);
    }

    // Test burn block failed with other user
    #[test(aptos = @0x1, account = @movecraft, creator = @0x123, user = @0x124)]
    #[expected_failure(abort_code = ENOT_BLOCK_OWNER, location = Self)]
    fun test_burn_block_failed_other_owner(aptos: &signer, account: &signer, creator: &signer, user: &signer) acquires State, Block {
        setup_test(aptos, account, creator);
        create_account_for_test(signer::address_of(user));

        mint_by_type(creator, LOG_BLOCK_TYPE);
        mint_by_type(creator, PLANK_BLOCK_TYPE);

        burn_block(creator, 1);
        burn_block(user, 2);
    }

    // Test stack block
    #[test(aptos = @0x1, account = @movecraft, creator = @0x123)]
    fun test_stack_block(aptos: &signer, account: &signer, creator: &signer) acquires State, Block {
        setup_test(aptos, account, creator);

        mint_by_type(creator, LOG_BLOCK_TYPE);
        mint_by_type(creator, LOG_BLOCK_TYPE);
        mint_by_type(creator, LOG_BLOCK_TYPE);
        stack_block(creator, 1, 2);
        stack_block(creator, 1, 3);

        let (name, type, count, stackable) = get_block(1);
        assert!(count == 3, 101);
    }

    // Test burn block failed with other user
    #[test(aptos = @0x1, account = @movecraft, creator = @0x123)]
    #[expected_failure(abort_code = ENOT_STACKABLE, location = Self)]
    fun test_stack_block_failed_other_type(aptos: &signer, account: &signer, creator: &signer) acquires State, Block {
        setup_test(aptos, account, creator);

        mint_by_type(creator, LOG_BLOCK_TYPE);
        mint_by_type(creator, LOG_BLOCK_TYPE);
        mint_by_type(creator, PLANK_BLOCK_TYPE);
        stack_block(creator, 1, 2);
        stack_block(creator, 1, 3);
    }
    
}