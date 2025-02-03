// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Orchestr.ai Registry Contract
 * @notice Manages job creation, execution, and payment distribution for AI agent collaborations
 * @dev Implements reentrancy protection and pausable functionality for security
 */
contract OrchestrAIRegistry is ReentrancyGuard, Pausable, Ownable {
    // ============ Custom Errors ============

    error InvalidArrayLength();
    error InsufficientPayment();
    error InvalidJobStatus();
    error InvalidRating();
    error UnauthorizedAccess();
    error JobNotFound();
    error NoBalanceAvailable();
    error TransferFailed();
    error InvalidInferenceProof();

    // ============ Type Definitions ============

    enum JobStatus {
        PENDING, // Job created but not yet started
        ONGOING, // Job is currently being processed
        COMPLETED, // Job completed successfully
        CANCELLED // Job cancelled (refund may be required)

    }

    struct Job {
        address payable client; // Address of the job creator
        uint256 jobId; // Unique identifier for the job
        uint256 totalAmount; // Total payment amount for the job
        uint256 createdAt; // Timestamp when job was created
        uint256 completedAt; // Timestamp when job was completed
        address[] assignedAgents; // Array of AI agent addresses assigned to this job
        uint256[] agentPayments; // Corresponding payment amounts for each agent
        JobStatus status; // Current status of the job
        uint8 rating; // Client rating (1-5 stars)
        bool isRated; // Whether the job has been rated
        bytes32[] inferenceHashes; // Array of hashes for each agent's zkTLS inference proof
        bool[] inferenceVerified; // Array tracking verification status for each inference
    }

    struct Agent {
        address payable owner; // Address of the agent owner
        string metadata; // IPFS hash containing agent details/capabilities
        uint256 totalEarned; // Total amount earned by this agent
        uint256 availableBalance; // Current withdrawable balance
        uint256 jobsCompleted; // Number of jobs completed
        bool isActive; // Whether the agent is currently active
    }

    // ============ State Variables ============

    /// @dev Counter for generating unique job IDs
    uint256 private nextJobId;

    /// @dev Mapping from job ID to Job struct
    mapping(uint256 => Job) public jobs;

    /// @dev Mapping from agent address to Agent struct
    mapping(address => Agent) public agents;

    /// @dev Mapping from client address to array of their job IDs
    mapping(address => uint256[]) public clientJobs;

    /// @dev Mapping from agent address to array of their job IDs
    mapping(address => uint256[]) public agentJobs;

    // ============ Events ============

    event AgentRegistered(address indexed agentAddress, address indexed owner, string metadata);
    event JobCreated(uint256 indexed jobId, address indexed client, uint256 totalAmount);
    event JobStarted(uint256 indexed jobId, address[] agents);
    event JobCompleted(uint256 indexed jobId, bytes32[] inferenceHashes);
    event JobCancelled(uint256 indexed jobId);
    event PaymentDistributed(uint256 indexed jobId, address[] agents, uint256[] amounts);
    event AgentWithdrawal(address indexed agentAddress, uint256 amount);
    event JobRated(uint256 indexed jobId, uint8 rating);
    event InferenceVerified(uint256 indexed jobId, uint256 indexed agentIndex, bytes32 inferenceHash);

    // ============ Modifiers ============

    modifier onlyAgentOwner(address agentAddress) {
        if (agents[agentAddress].owner != msg.sender) {
            revert UnauthorizedAccess();
        }
        _;
    }

    modifier onlyJobClient(uint256 jobId) {
        if (jobs[jobId].client != msg.sender) {
            revert UnauthorizedAccess();
        }
        _;
    }

    modifier jobExists(uint256 jobId) {
        if (jobs[jobId].client == address(0)) {
            revert JobNotFound();
        }
        _;
    }

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Core Functions ============

    /**
     * @notice Register a new AI agent on the platform
     * @param agentAddress The wallet address for the AI agent
     * @param metadata IPFS hash containing agent details
     */
    function registerAgent(address payable agentAddress, string calldata metadata) external whenNotPaused {
        if (agents[agentAddress].owner != address(0)) {
            revert("Agent already registered");
        }

        agents[agentAddress] = Agent({
            owner: payable(msg.sender),
            metadata: metadata,
            totalEarned: 0,
            availableBalance: 0,
            jobsCompleted: 0,
            isActive: true
        });

        emit AgentRegistered(agentAddress, msg.sender, metadata);
    }

    /**
     * @notice Create a new job with payment
     * @param assignedAgents Array of AI agent addresses to work on the job
     * @param agentPayments Array of payment amounts for each agent
     */
    function createJob(address[] calldata assignedAgents, uint256[] calldata agentPayments)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        if (assignedAgents.length != agentPayments.length || assignedAgents.length == 0) {
            revert InvalidArrayLength();
        }

        uint256 totalPayments = 0;
        for (uint256 i = 0; i < agentPayments.length; i++) {
            totalPayments += agentPayments[i];
        }

        if (msg.value < totalPayments) {
            revert InsufficientPayment();
        }

        uint256 jobId = nextJobId++;

        bool[] memory initialVerification = new bool[](assignedAgents.length);
        bytes32[] memory initialHashes = new bytes32[](assignedAgents.length);

        jobs[jobId] = Job({
            client: payable(msg.sender),
            jobId: jobId,
            totalAmount: msg.value,
            createdAt: block.timestamp,
            completedAt: 0,
            assignedAgents: assignedAgents,
            agentPayments: agentPayments,
            status: JobStatus.PENDING,
            rating: 0,
            isRated: false,
            inferenceHashes: initialHashes,
            inferenceVerified: initialVerification
        });

        clientJobs[msg.sender].push(jobId);
        for (uint256 i = 0; i < assignedAgents.length; i++) {
            agentJobs[assignedAgents[i]].push(jobId);
        }

        emit JobCreated(jobId, msg.sender, msg.value);
    }

    /**
     * @notice Start a pending job
     * @param jobId The ID of the job to start
     */
    function startJob(uint256 jobId) external whenNotPaused jobExists(jobId) {
        Job storage job = jobs[jobId];
        if (job.status != JobStatus.PENDING) {
            revert InvalidJobStatus();
        }

        job.status = JobStatus.ONGOING;
        emit JobStarted(jobId, job.assignedAgents);
    }

    /**
     * @notice Submit and verify inference proof for a specific agent in a job
     * @param jobId The ID of the job
     * @param agentIndex Index of the agent in the job's assignedAgents array
     * @param inferenceHash Hash of the zkTLS inference proof
     */
    function verifyAgentInference(uint256 jobId, uint256 agentIndex, bytes32 inferenceHash)
        external
        whenNotPaused
        jobExists(jobId)
    {
        Job storage job = jobs[jobId];
        if (job.status != JobStatus.ONGOING) {
            revert InvalidJobStatus();
        }
        if (agentIndex >= job.assignedAgents.length) {
            revert InvalidArrayLength();
        }

        // Verify inference
        if (!verifyInference(inferenceHash)) {
            revert InvalidInferenceProof();
        }

        job.inferenceHashes[agentIndex] = inferenceHash;
        job.inferenceVerified[agentIndex] = true;

        emit InferenceVerified(jobId, agentIndex, inferenceHash);

        // Check if all inferences are verified
        bool allVerified = true;
        for (uint256 i = 0; i < job.inferenceVerified.length; i++) {
            if (!job.inferenceVerified[i]) {
                allVerified = false;
                break;
            }
        }

        // If all verified, complete the job and distribute payments
        if (allVerified) {
            _completeJobAndPay(jobId);
        }
    }

    /**
     * @notice Internal function to complete job and distribute payments
     * @param jobId The ID of the job to complete
     */
    function _completeJobAndPay(uint256 jobId) private {
        Job storage job = jobs[jobId];
        job.status = JobStatus.COMPLETED;
        job.completedAt = block.timestamp;

        // Distribute payments to agents
        for (uint256 i = 0; i < job.assignedAgents.length; i++) {
            address agent = job.assignedAgents[i];
            uint256 payment = job.agentPayments[i];

            agents[agent].availableBalance += payment;
            agents[agent].totalEarned += payment;
            agents[agent].jobsCompleted++;
        }

        emit JobCompleted(jobId, job.inferenceHashes);
        emit PaymentDistributed(jobId, job.assignedAgents, job.agentPayments);
    }

    /**
     * @notice Withdraw available balance for an agent
     * @param agentAddress The address of the agent to withdraw funds from
     */
    function withdrawAgentBalance(address payable agentAddress)
        external
        whenNotPaused
        nonReentrant
        onlyAgentOwner(agentAddress)
    {
        uint256 amount = agents[agentAddress].availableBalance;
        if (amount == 0) {
            revert NoBalanceAvailable();
        }

        agents[agentAddress].availableBalance = 0;

        (bool success,) = agentAddress.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }

        emit AgentWithdrawal(agentAddress, amount);
    }

    /**
     * @notice Rate a completed job
     * @param jobId The ID of the job to rate
     * @param rating Rating from 1-5
     */
    function rateJob(uint256 jobId, uint8 rating) external whenNotPaused jobExists(jobId) onlyJobClient(jobId) {
        if (rating < 1 || rating > 5) {
            revert InvalidRating();
        }

        Job storage job = jobs[jobId];
        if (job.status != JobStatus.COMPLETED) {
            revert InvalidJobStatus();
        }
        if (job.isRated) {
            revert("Job already rated");
        }

        job.rating = rating;
        job.isRated = true;

        emit JobRated(jobId, rating);
    }

    // ============ View Functions ============

    function getClientJobs(address client) external view returns (uint256[] memory) {
        return clientJobs[client];
    }

    function getAgentJobs(address agentAddress) external view returns (uint256[] memory) {
        return agentJobs[agentAddress];
    }

    function getJobDetails(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function getAgentDetails(address agentAddress) external view returns (Agent memory) {
        return agents[agentAddress];
    }

    // ============ Internal Functions ============

    /**
     * @notice Verify the zkTLS inference proof
     * @dev TODO: Implement zkTLS proof verification on Eigen Layer
     */
    function verifyInference(bytes32 inferenceHash) internal pure returns (bool) {
        // TODO: Implement zkTLS proof verification on Eigen Layer
        return inferenceHash != bytes32(0);
    }

    // ============ Emergency Functions ============

    /**
     * @notice Pause all contract operations
     * @dev Only callable by contract owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract operations
     * @dev Only callable by contract owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
