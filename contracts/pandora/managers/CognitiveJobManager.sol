pragma solidity ^0.4.23;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../../lifecycle/Initializable.sol";
import "../lottery/RandomEngine.sol";
import "./ICognitiveJobManager.sol";
import "./WorkerNodeManager.sol";
import "../../jobs/IComputingJob.sol";
import "../token/Reputation.sol";

import {CognitiveJobLib as CJL} from "..\..\libraries\CognitiveJobLib.sol";
import {JobQueueLib as JQL} from "../../libraries/JobQueueLib.sol";

/**
 * @title Pandora Smart Contract
 * @author "Dr Maxim Orlovsky" <orlovsky@pandora.foundation>
 *
 * @dev # Pandora Smart Contract
 *
 * Main & root contract implementing the first level of Pandora Boxchain consensus
 * See section ["3.3. Proof of Cognitive Work (PoCW)" in Pandora white paper](https://steemit.com/cryptocurrency/%40pandoraboxchain/world-decentralized-ai-on-blockchain-with-cognitive-mining-and-open-markets-for-data-and-algorithms-pandora-boxchain)
 * for more details.
 */

contract CognitiveJobManager is Initializable, ICognitiveJobManager, WorkerNodeManager {

    /*******************************************************************************************************************
     * ## Storage
     */

    /// ### Public variables

    /// @dev Contract, that store rep. values for each address
    IReputation reputation;

    /// @dev Returns total count of active jobs
    function cognitiveJobsCount() onlyInitialized view public returns (uint256) {
        return cognitiveJobs.length;
    }

    // Deposits from clients used as payment for work
    mapping(address => uint256) public deposits;

    /// @notice Status code returned by `createCognitiveJob()` method when no Idle WorkerNodes were available
    /// and job was not created but was put into the job queue to be processed lately
    uint8 constant public RESULT_CODE_ADD_TO_QUEUE = 0;
    /// @notice Status code returned by `createCognitiveJob()` method when CognitiveJob was created successfully
    uint8 constant public RESULT_CODE_JOB_CREATED = 1;

    uint256 constant public REQUIRED_DEPOSIT = 500 finney;

    /// ### Private and internal variables

    /// @dev Contract implementing lottery interface for workers selection. Only internal usage
    /// by `createCognitiveJob` function
    ILotteryEngine internal workerLotteryEngine;

    // Queue for CognitiveJobs kept while no Idle WorkerNodes available
    /// @dev Cognitive job queue used for case when no idle workers available
    using JQL for JQL.Queue;
    JQL.Queue internal queue;

    // Controller for CognitiveJobs
    using CJL for CJL.Controller;
    CJL.Controller internal controller;

    using SafeMath for uint;

    /*******************************************************************************************************************
     * ## Events
     */

    /// @dev Event firing when a new cognitive job created
    event CognitiveJobCreated(bytes32 jobId);

    /// @dev Event firing when a new cognitive job queued
    event CognitiveJobQueued(bytes32 jobId);

    /*******************************************************************************************************************
     * ## Constructor and initialization
     */

    /// ### Constructor
    /// @dev Constructor receives addresses for the owners of whitelisted worker nodes, which will be assigned an owners
    /// of worker nodes contracts
    constructor(
        ICognitiveJobFactory _jobFactory, /// Factory class for creating CognitiveJob contracts
        IWorkerNodeFactory _nodeFactory, /// Factory class for creating WorkerNode contracts
        IReputation _reputation
    )
    public
    WorkerNodeManager(_nodeFactory) {

        // Must ensure that the supplied factories are already created contracts
        require(_jobFactory != address(0));

        // Assign factories to storage variables
        cognitiveJobFactory = _jobFactory;

        // Init reputation storage contract
        reputation = _reputation;

        // Initializing worker lottery engine
        workerLotteryEngine = new RandomEngine();
    }

    /*******************************************************************************************************************
     * ## Modifiers
     */


    /*******************************************************************************************************************
     * ## Functions
     */

    /// ### Public

    /// @notice Test whether the given `job` is registered as an active job and not completed
    function isActiveJob(
        bytes32 _jobId
    )
    view
    public
    returns (
        bool
    ) {
        return controller.jobAddresses[_jobId] != 0;
    }

    function getCognitiveJobDetails(bytes32 _jobId)
    public
    returns (
        address, address, uint256, bytes32, bytes32[], bytes[]
    ) {
        CJL.CognitiveJob memory job = controller.cognitiveJobs[_self.jobIndexes[_jobId]];
        return (
            job.kernel,
            job.dataset,
            job.complexity,
            job.description,
            job.activeWorkers,
            job.ipfsResults
        );
    }

    function getCognitiveJobProgressInfo(bytes32 _jobId)
    public
    returns(
        uint32[], bool[], uint8, uint8
    ) {
        CJL.CognitiveJob memory job = controller.cognitiveJobs[_self.jobIndexes[_jobId]];
        return (
            job.responseTimestamps,
            job.responseFlags,
            job.progress,
            job.state
        );
    }

    /// ### External

    /// @notice Creates and returns new cognitive job contract and starts actual cognitive work instantly
    /// @dev Core function creating new cognitive job contract and returning it back to the caller
    function createCognitiveJob(
        IKernel _kernel, /// Pre-initialized kernel data entity contract
        IDataset _dataset, /// Pre-initialized dataset entity contract
        uint256 _complexity,
        bytes32 _description
    )
    external
    payable
    returns (
        bytes32 o_jobId, /// Newly created cognitive jobs (starts automatically)
        uint8 o_resultCode /// result code of creating job, 0 - job queued (no available workers) , 1 - job created
    ) {

        // Restriction for batches count came from potential high gas usage in JobQueue processing
        // todo check batches limit with tests
        uint8 batchesCount = _dataset.batchesCount();
        require(batchesCount <= 10);

        // Dimensions of the input data and neural network input layer must be equal
        require(_kernel.dataDim() == _dataset.dataDim());

        // @todo check payment corresponds to required amount + gas payment - (fixed value + #batches * value)
        require(msg.value >= REQUIRED_DEPOSIT);

        // Counting number of available worker nodes (in Idle state)
        // Since Solidity does not supports dynamic in-memory arrays (yet), has to be done in two-staged way:
        // first by counting array size and then by allocating and populating array itself

        uint256 estimatedSize = _countIdleWorkers();
        if (estimatedSize < uint256(batchesCount)) {
            // Put task in queue
            o_resultCode = RESULT_CODE_ADD_TO_QUEUE;
            queue.put(
                address(_kernel),
                address(_dataset),
                msg.sender,
                msg.value,
                batchesCount,
                _complexity,
                _description);
            //  Hold payment from customer
            deposits[msg.sender] = deposits[msg.sender].add(msg.value);
            emit CognitiveJobQueued(o_jobId);
        } else {
            // Job created instantly
            // Return funds to sender
            msg.sender.transfer(msg.value);
            // Initializing in-memory array for idle node list and populating it with data
            IWorkerNode[] memory idleWorkers = _listIdleWorkers(estimatedSize);

            // Running lottery to select worker node to be assigned cognitive job contract
            IWorkerNode[] memory assignedWorkers = _selectWorkersWithLottery(idleWorkers, batchesCount);

            o_jobId = _initCognitiveJob(_kernel, _dataset, assignedWorkers, _complexity, _description);
            o_resultCode = RESULT_CODE_JOB_CREATED;

            emit CognitiveJobCreated(o_jobId);
        }
    }

    /// @notice Can"t be called by the user, for internal use only
    /// @dev Function must be called only by the master node running cognitive job. It completes the job, updates
    /// worker node back to `Idle` state (in smart contract) and removes job contract from the list of active contracts
    function finishCognitiveJob(
        bytes32 jobId
    )
    external
    //todo check function caller
    {
        uint16 index = jobAddresses[msg.sender];
        require(index != 0);
        index--;

        IComputingJob job = cognitiveJobs[index];
        require(address(job) == msg.sender);

        // Increase reputation of workers involved to computation
        uint256 reputationReward = job.complexity();
        //todo add koef for complexity-reputation
        for (uint256 i = 0; i <= job.activeWorkersCount(); i++) {
            reputation.incrReputation(address(i), reputationReward);
        }
    }

    function getQueueDepth(
        // No arguments
    )
    external
    returns (uint256)
    {
        return queue.queueDepth();
    }

    /// @notice Private function which checks queue of jobs and create new jobs
    /// #dev Function is called by worker owner, after finalize congitiveJob (but could be called by any address)
    /// to unlock worker's idle state and allocate newly freed WorkerNodes to perform cognitive jobs from the queue.
    function checkJobQueue(
    // No arguments
    )
    public
    onlyInitialized {
        JQL.QueuedJob memory queuedJob;
        // Iterate queue and check queue depth

        uint256 limitQueueReq = queue.queueDepth();
        limitQueueReq = limitQueueReq > 1 ? 1 : limitQueueReq;
        // todo check limit (2) for queue requests with tests

        for (uint256 k = 0; k < limitQueueReq; k++) {

            // Count remaining gas
            uint initialGas = gasleft();

            // Counting number of available worker nodes (in Idle state)
            uint256 estimatedSize = _countIdleWorkers();

            // There must be at least one free worker node
            if (estimatedSize <= 0) {
                break;
            }

            // Initializing in-memory array for idle node list and populating it with data
            IWorkerNode[] memory idleWorkers = _listIdleWorkers(estimatedSize);
            uint actualSize = idleWorkers.length;
            if (actualSize != estimatedSize) {
                break;
            }

            // Check number of batches with number of idle workers
            if (!queue.checkElementBatches(actualSize)) {
                break;
            }

            // uint value1 = cognitiveJobQueue.queueDepth();
            uint256 value;
            // Value from queuedJob deposit
            (queuedJob, value) = queue.requestJob();

            // Running lottery to select worker node to be assigned cognitive job contract
            IWorkerNode[] memory assignedWorkers = _selectWorkersWithLottery(idleWorkers, queuedJob.batches);

            // @fixme remove in upcoming version
            // (temporarily due to worker controller absence) convert workers array to address array
            address[] workerAddresses = address[](assignedWorkers.length);
            for (uint256 i = 0; i < workerAddresses.length; i++) {
                workerAddresses[i] = address(assignedWorkers[i]);
            }

            IComputingJob createdCognitiveJob = _initQueuedJob(queuedJob, assignedWorkers);

            //todo assign job to each worker
            for (uint256 i = 0; i < assignedWorkers.length; i++) {
                assignedWorkers[i].assignJob(o_jobId);
            }

            emit CognitiveJobCreated(createdCognitiveJob, RESULT_CODE_JOB_CREATED);

            // Count used funds for queue
            //todo set limit for gasprice
            uint weiUsed = (57000 + initialGas - gasleft()) * tx.gasprice;
            //57k of gas used for transfers and storage writing
            if (weiUsed > value) {
                weiUsed = value; //weiUsed should not exceed deposit fixme set constraint to minimal deposit
            }

            //Withdraw from customer's deposit
            deposits[queuedJob.customer] = deposits[queuedJob.customer].sub(value);

            // Gas refund to node
            tx.origin.transfer(weiUsed);

            // Return remaining deposit to customer
            if (value - weiUsed != 0) {
                queuedJob.customer.transfer(value - weiUsed);
            }
        }
    }

    function commitProgress(
        bytes32 _jobId,
        uint _percent)
    external {
        //todo implement check msg.sender with worker controller
        CJL.commitProgress(_jobId, msg.sender, _percent);
    }

    function _initQueuedJob(JobQueueLib.QueuedJob queuedJob, IWorkerNode[] assignedWorkers)
    private
    onlyInitialized
    returns (
        bytes32 jobId
    ) {
        jobId = _initCognitiveJob(
            IKernel(queuedJob.kernel),
            IDataset(queuedJob.dataset),
            assignedWorkers,
            queuedJob.complexity,
            queuedJob.description
        );
    }

    /// @notice Can"t be called by the user or other contract: for private use only
    /// @dev Creates cognitive job contract, saves it to storage and fires global event to notify selected worker node.
    /// Used both by `createCognitiveJob()` and `_checksJobQueue()` methods.
    function _initCognitiveJob(
        IKernel _kernel, /// Pre-initialized kernel data entity contract (taken from `createCognitiveJob` arguments or
    /// from the the `cognitiveJobQueue` `QueuedJob` structure)
        IDataset _dataset, /// Pre-initialized dataset entity contract (taken from `createCognitiveJob` arguments or
    /// from the the `cognitiveJobQueue` `QueuedJob` structure)
        IWorkerNode[] _assignedWorkers, /// Array of workers assigned for the job by the lottery engine //todo change to address
        uint256 _complexity,
        bytes32 _description
    )
    private
    onlyInitialized
    returns (
        bytes32 o_jobId /// Created cognitive job ID
    ) {

        // @fixme remove in upcoming version
        // (temporarily due to worker controller absence) convert workers array to address array
        address[] workerAddresses = address[](assignedWorkers.length);
        for (uint256 i = 0; i < workerAddresses.length; i++) {
            workerAddresses[i] = address(assignedWorkers[i]);
        }

        o_jobId = CJL.createCognitiveJob(
            address(_kernel),
            address(_dataset),
            _assignedWorkers,
            _complexity,
            _description);

        //assign each worker to job
        for (uint256 i = 0; i < assignedWorkers.length; i++) {
            assignedWorkers[i].assignJob(o_jobId);
        }
    }

    /// @notice Can"t be called by the user or other contract: for private use only
    /// @dev Running lottery to select random worker nodes from the provided list. Used by both `createCognitiveJob`
    /// and `_checksJobQueue` functions.
    function _selectWorkersWithLottery(
        IWorkerNode[] _idleWorkers, /// Pre-defined pool of Idle WorkerNodes to select from
        uint _numberWorkersRequired /// Number of workers required by cognitive job, match with number of batches
    )
    private
    returns (
        IWorkerNode[] assignedWorkers /// Resulting sublist of the selected WorkerNodes
    ) {
        assignedWorkers = new IWorkerNode[](_numberWorkersRequired);
        uint no = workerLotteryEngine.getRandom(assignedWorkers.length);
        for (uint i = 0; i < assignedWorkers.length; i++) {
            assignedWorkers[i] = _idleWorkers[no];
            no = (no == assignedWorkers.length - 1) ? 0 : no + 1;
        }
    }

    /// @notice Can"t be called by the user or other contract: for private use only
    /// @dev Pre-count amount of available Idle WorkerNodes. Required to allocate in-memory list of WorkerNodes.
    function _countIdleWorkers(
    // No arguments
    )
    private
    view
    returns (
        uint o_estimatedSize /// Amount of currently available (Idle) WorkerNodes
    ) {
        o_estimatedSize = 0;
        for (uint i = 0; i < workerNodes.length; i++) {
            if (workerNodes[i].currentState() == workerNodes[i].Idle()) {
                o_estimatedSize++;
            }
        }
        return o_estimatedSize;
    }

    /// @notice Can"t be called by the user or other contract: for private use only
    /// @dev Allocates and returns in-memory array of all Idle WorkerNodes taking estimated size as an argument
    /// (returned by `_countIdleWorkers()`)
    function _listIdleWorkers(
        uint _estimatedSize /// Size of array to return
    )
    private
    view
    returns (
        IWorkerNode[] /// Returned array of all Idle WorkerNodes
    ) {
        IWorkerNode[] memory idleWorkers = new IWorkerNode[](_estimatedSize);
        uint256 actualSize = 0;
        for (uint j = 0; j < workerNodes.length; j++) {
            if (workerNodes[j].currentState() == workerNodes[j].Idle()) {
                idleWorkers[actualSize++] = workerNodes[j];
            }
        }
        return idleWorkers;
    }
}