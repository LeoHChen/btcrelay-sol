pragma solidity >=0.4.22 <0.6.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./Utils.sol";

/// @title BTCRelay implementation in Solidity
/// @notice Stores Bitcoin block _headers and heaviest (PoW) chain tip, and allows verification of transaction inclusion proofs 
contract BTCRelay {
    
    using SafeMath for uint256;
    using Utils for bytes;
    
    struct Header {
        uint32 version; // block cersion (4 bytes)
        uint32 time; // Unix epoch timestamp (4 bytes) - in BE!
        //uint32 nBits; // encoded diff. target (4 bytes)
        uint32 nonce; // PoW solution nonce (4 bytes)
        uint32 blockHeight; // position of block - not part of header
        bytes32 prevBlockHash; // previous block hash (32 bytes)
        bytes32 merkleRoot; // root hash of transaction merkle tree (32 bytes)
        uint256 target; // diff. target - decoded from compressed 4 byte nBits
        uint256 chainWork; // accumulated PoW at the eight of this block - not part of header
    }
    mapping(bytes32 => Header) public _headers;
    
    
    // Potentially more optimal - need to add chainWork and blockHeight though...
    //mapping(bytes32 => bytes) public _headers;

    bytes32 public _heaviestBlock; // block with the highest chainWork, i.e., blockchain tip
    uint256 public _highScore; // highest chainWork, i.e., accumulated PoW at current blockchain tip
    bytes32 public _lastDifficultyAdjustmentBlock; // block of last difficulty adjustment blockHeight (blockHeight mod DIFFICULTY_ADJUSTMENT_INVETVAL = 0)

    // CONSTANTS
    /**
    * Bitcoin difficulty constants
    * TODO: move this to constructor before deployment
    */ 
    uint256 public constant DIFFICULTY_ADJUSTMENT_INVETVAL = 2016;
    uint256 public constant TARGET_TIMESPAN = 14 * 24 * 60 * 60; // 2 weeks 
    uint256 public constant UNROUNDED_MAX_TARGET = 2**224 - 1; 
    uint256 public constant TARGET_TIMESPAN_DIV_4 = TARGET_TIMESPAN / 4; // store division as constant to save costs
    uint256 public constant TARGET_TIMESPAN_MUL_4 = TARGET_TIMESPAN * 4; // store multiplucation as constant to save costs

    // ERROR CODES
    // error codes for storeBlockHeader
    uint256 public constant ERR_DIFFICULTY = 10010;  // difficulty didn't match current difficulty
    uint256 public constant ERR_RETARGET = 10020;  // difficulty didn't match retarget
    uint256 public constant ERR_NO_PREV_BLOCK = 10030;
    uint256 public constant ERR_BLOCK_ALREADY_EXISTS = 10040;
    uint256 public constant ERR_PROOF_OF_WORK = 10090;
    // error codes for verifyTx
    uint256 public constant ERR_BAD_FEE = 20010;
    uint256 public constant ERR_CONFIRMATIONS = 20020;
    uint256 public constant ERR_CHAIN = 20030;
    uint256 public constant ERR_MERKLE_ROOT = 20040;
    uint256 public constant ERR_TX_64BYTE = 20050;

    // EVENTS
    /**
    * @param _blockHash block header hash of block header submitted for storage
    * @param _returnCode block blockHeight if validation was successful, error code otherwise
    */
    event StoreHeader(bytes32 indexed _blockHash, uint256 indexed _returnCode);
    /**
    * @param _txid block header hash of block header submitted for storage
    * @param _returnCode none if transaction verification successful, error code otherwise
    */
    event VerityTransaction(bytes32 indexed _txid, uint256 indexed _returnCode);

    /**
    * @notice Initialized BTCRelay with provided block, i.e., defined the first block of the stored chain. 
    * @dev TODO: check issue with "blockHeight mod 2016 = 2015" requirement (old btc relay!). Alexei: IMHO should be called with "blockHeight mod 2016 = 0"
    * @param blockHeaderHash block hedaer hash 
    * @param blockHeight block blockHeight
    * @param target target of block  header (necessary for difficulty target validation of next block)
    * @param chainWork total accumulated PoW at given block blockHeight/hash 
    */
    constructor(bytes32 blockHeaderHash, uint32 blockHeight, uint32 time, bytes32 merkleRoot, uint256 target, uint256 chainWork) public {
        _heaviestBlock = blockHeaderHash;
        _lastDifficultyAdjustmentBlock = blockHeaderHash;
        _highScore = chainWork;
        
        _headers[blockHeaderHash].blockHeight = blockHeight;
        _headers[blockHeaderHash].target = target;
        _headers[blockHeaderHash].chainWork = chainWork;
        _headers[blockHeaderHash].time = time;
        _headers[blockHeaderHash].merkleRoot = merkleRoot;
    }

    
    function storeBlockHeader(bytes memory blockHeaderBytes) public {
        bytes32 hashPrevBlock = blockHeaderBytes.slice(4, 32).flipBytes().toBytes32();
        bytes memory hashCurrentBlockBytes = dblShaFlip(blockHeaderBytes);
        bytes32 hashCurrentBlock = hashCurrentBlockBytes.toBytes32();

                
        // Block hash must be greated 0        
        require(hashCurrentBlock > 0, "Submitted block has invalid hash");
        // Fail if previous block hash not in current state of main chain
        require(_headers[hashPrevBlock].prevBlockHash != 0, "Previous block hash not in found current state of main chain");

        // Fails if previous block header is not stored
        uint256 chainWorkPrevBlock = getChainWork(hashPrevBlock);
        uint256 target = nBitsToTarget(blockHeaderBytes.slice(72, 4).flipBytes().bytesToUint());
        uint32 blockHeight = 1 + _headers[hashPrevBlock].blockHeight;
        
        // Check the PoW solution matches the target specified in the block header
        require(hashCurrentBlockBytes.bytesToUint() < target, "PoW solution hash does not match difficulty target specified in block header!");
        // Check the specified difficulty target is correct:
        // If retarget: according to Bitcoin's difficulty adjustment mechanism;
        // Else: same as last block. 
        require(correctDifficultyTarget(hashPrevBlock, blockHeight, target), "Incorrect difficulty target specified in block header!");


        _headers[hashCurrentBlock].version = uint32(blockHeaderBytes.slice(0,4).flipBytes().bytesToUint());
        _headers[hashCurrentBlock].time = uint32(blockHeaderBytes.slice(68,4).bytesToUint());
        _headers[hashCurrentBlock].nonce =  uint32(blockHeaderBytes.slice(76, 4).flipBytes().bytesToUint());
        _headers[hashCurrentBlock].blockHeight = blockHeight;
        _headers[hashCurrentBlock].prevBlockHash = hashPrevBlock;
        _headers[hashCurrentBlock].merkleRoot = blockHeaderBytes.slice(36,32).toBytes32();
        _headers[hashCurrentBlock].target = target;
        
        // https://en.bitcoin.it/wiki/Difficulty
        // TODO: check correct conversion here
        uint256 difficulty = 0x00000000FFFF0000000000000000000000000000000000000000000000000000 / target;
        uint256 chainWork = chainWorkPrevBlock + difficulty;
        _headers[hashCurrentBlock].chainWork = chainWork;

        if(chainWork > _highScore){
            _heaviestBlock = hashCurrentBlock;
            _highScore = chainWork;
        }
        emit StoreHeader(hashCurrentBlock, blockHeight);
    }

    // HELPER FUNCTIONS


    /**
    * @notice Performns Bitcoin-like double sha256 (LE!)
    * @param data Bytes to be flipped and double hashed 
    * @return Reversed and double hashed representation of parsed data
    */
    function dblShaFlip(bytes memory data) private pure returns (bytes memory){
        abi.encodePacked(sha256(abi.encodePacked(sha256(data)))).flipBytes();
    }

    /**
    * @notice Calculates the PoW difficulty target from compressed nBits representation, 
    * according to https://bitcoin.org/en/developer-reference#target-nbits
    * @param nBits Compressed PoW target representation
    * @return PoW difficulty target computed from nBits
    */
    function nBitsToTarget(uint256 nBits) private pure returns (uint256){
        uint256 exp = uint256(nBits) >> 24;
        uint256 c = uint256(nBits) & 0xffffff;
        uint256 target = uint256((c * 2**(8*(exp - 3))));
        return target;
    }

    /**
    * @notice Checks if the difficulty target should be adjusted at this block blockHeight
    * @param blockHeight block blockHeight to be checked
    * @return true, if block blockHeight is at difficulty adjustment interval, otherwise false
    */
    function difficultyShouldBeAdjusted(uint256 blockHeight) private pure returns (bool){
        return blockHeight % DIFFICULTY_ADJUSTMENT_INVETVAL == 0;
    }

    /**
    * @notice Verifies the currently submitted block header has the correct difficutly target, based on contract parameters
    * @dev Called from storeBlockHeader. TODO: think about emitting events in this function to identify the reason for failures
    * @param hashPrevBlock Previous block hash (necessary to retrieve previous target)
    */
    function correctDifficultyTarget(bytes32 hashPrevBlock, uint256 blockHeight, uint256 target) private view returns(bool) {
        uint256 prevTarget = _headers[hashPrevBlock].target;
        
        if(!difficultyShouldBeAdjusted(blockHeight)){
            // Difficulty not adjusted at this block blockHeight
            if(target != prevTarget && prevTarget != 0){
                return false;
            }
        } else {
            // Difficulty should be adjusted at this block blockHeight => check if adjusted correctly!
            uint256 prevTime = _headers[hashPrevBlock].time;
            uint256 startTime = _headers[_lastDifficultyAdjustmentBlock].time;
            uint256 newTarget = computeNewTarget(prevTime, startTime, prevTarget);
            return target == newTarget;
        }
    }

    /**
    * @notice Computes the new difficulty target based on the given parameters, 
    * according to: https://github.com/bitcoin/bitcoin/blob/78dae8caccd82cfbfd76557f1fb7d7557c7b5edb/src/pow.cpp 
    * @param prevTime timestamp of previous block 
    * @param startTime timestamp of last re-target
    * @param prevTarget PoW difficulty target of previous block
    */
    function computeNewTarget(uint256 prevTime, uint256 startTime, uint256 prevTarget) private pure returns(uint256){
        uint256 actualTimeSpan = prevTime - startTime;
        if(actualTimeSpan < TARGET_TIMESPAN_DIV_4){
            actualTimeSpan = TARGET_TIMESPAN_DIV_4;
        } 
        if(actualTimeSpan > TARGET_TIMESPAN_MUL_4){
            actualTimeSpan = TARGET_TIMESPAN_MUL_4;
        }

        uint256 newTarget = actualTimeSpan.mul(prevTarget).div(TARGET_TIMESPAN);
        if(newTarget > UNROUNDED_MAX_TARGET){
            newTarget = UNROUNDED_MAX_TARGET;
        }
        return newTarget;
    }

    // GETTERS

    function getChainWork(bytes32 blockHeaderHash) public view returns(uint256){
        return(
            _headers[blockHeaderHash].chainWork
        );
    }

}