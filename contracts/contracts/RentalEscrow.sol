// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RentalNFT} from "./RentalNFT.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RentalEscrow is Ownable, ReentrancyGuard {
    IERC20 public usdc;
    uint8 private _platformFeePercentage;

    struct Rental {
        uint256 tokenId;
        address lender;
        address renter;
        uint256 rentalFee;
        uint256 securityDeposit;
        uint256 startTime;
        uint256 endTime;
        bool isActive;
        bool isReturned;
    }

    mapping(uint256 => Rental) public rentals;
    RentalNFT public rentalNFT;

    event RentalStarted(
        uint256 indexed tokenId,
        address indexed lender,
        address indexed renter,
        uint256 rentalFee,
        uint256 securityDeposit,
        uint256 duration
    );

    event RentalEnded(
        uint256 indexed tokenId,
        address indexed lender,
        address indexed renter,
        uint256 lenderFee,
        uint256 platformFee
    );

    constructor(
        address _rentalNFT,
        address _usdc,
        uint8 platformFee
    ) Ownable(msg.sender) {
        rentalNFT = RentalNFT(_rentalNFT);
        usdc = IERC20(_usdc);
        _platformFeePercentage = platformFee;
    }

    /**
     * @dev Start a rental for an item
     * @param tokenId: the ID of the item to rent
     * @param duration: the duration of the rental in days
     */
    function startRental(
        uint256 tokenId,
        uint32 duration
    ) external nonReentrant {
        require(duration > 0, "Duration must be greater than 0");
        require(rentals[tokenId].isActive == false, "Item is already rented");
        require(
            rentalNFT.ownerOf(tokenId) != msg.sender,
            "Cannot rent your own item"
        );

        RentalNFT.ItemDetails memory item = rentalNFT.getItemDetails(tokenId);
        require(item.isAvailable, "Item is not available for rent");

        // Check if escrow is approved to transfer the NFT
        require(
            rentalNFT.getApproved(tokenId) == address(this) ||
                rentalNFT.isApprovedForAll(item.lender, address(this)),
            "Escrow not approved to transfer NFT"
        );

        uint256 totalCost = uint256(item.dailyFee) *
            duration +
            uint256(item.securityDeposit);

        rentals[tokenId] = Rental({
            tokenId: tokenId,
            lender: item.lender,
            renter: msg.sender,
            rentalFee: uint256(item.dailyFee) * duration,
            securityDeposit: uint256(item.securityDeposit),
            startTime: block.timestamp,
            endTime: block.timestamp + duration * 1 days,
            isActive: true,
            isReturned: false
        });

        // Handle payment first
        require(
            usdc.transferFrom(msg.sender, address(this), totalCost),
            "USDC transfer failed"
        );

        // Update rental state in NFT contract
        rentalNFT.startRental(tokenId, msg.sender, duration);

        // Transfer NFT from lender to renter through escrow
        rentalNFT.transferFrom(item.lender, msg.sender, tokenId);

        emit RentalStarted(
            tokenId,
            item.lender,
            msg.sender,
            rentals[tokenId].rentalFee,
            rentals[tokenId].securityDeposit,
            duration
        );
    }

    /**
     * @dev End a rental for an item
     * @param tokenId: the ID of the item to return
     */
    function endRental(uint256 tokenId) external nonReentrant {
        Rental storage rental = rentals[tokenId];
        require(rental.isActive, "Rental is not active");
        require(rental.renter == msg.sender, "You are not the renter");

        // Check if escrow is approved to transfer the NFT back
        require(
            rentalNFT.getApproved(tokenId) == address(this) ||
                rentalNFT.isApprovedForAll(msg.sender, address(this)),
            "Escrow not approved to transfer NFT back"
        );

        uint256 platformFee = (rental.rentalFee * _platformFeePercentage) / 100;
        uint256 lenderRevenue = rental.rentalFee - platformFee;

        address lender = rental.lender;
        address renter = rental.renter;

        rental.isActive = false;
        rental.isReturned = true;

        // Update rental state in NFT contract
        rentalNFT.endRental(tokenId);

        // Transfer NFT back to lender through escrow
        rentalNFT.transferFrom(msg.sender, lender, tokenId);

        // Handle payments
        require(usdc.transfer(lender, lenderRevenue), "Lender transfer failed");

        require(
            usdc.transfer(owner(), platformFee),
            "Platform transfer failed"
        );

        require(
            usdc.transfer(renter, rental.securityDeposit),
            "Renter transfer failed"
        );

        emit RentalEnded(tokenId, lender, renter, lenderRevenue, platformFee);
    }

    /**
     * @dev Allow lender to approve escrow for managing their NFT
     * @param tokenId: the ID of the token to approve
     */
    function approveForRental(uint256 tokenId) external {
        require(
            rentalNFT.ownerOf(tokenId) == msg.sender,
            "Not the owner of this token"
        );
        // The lender should call approve directly on the NFT contract
        rentalNFT.approve(address(this), tokenId);
    }

    /**
     * @dev Get rental details
     * @param tokenId: the ID of the token
     */
    function getRentalDetails(
        uint256 tokenId
    ) external view returns (Rental memory) {
        return rentals[tokenId];
    }

    /**
     * @dev Check if a token is currently being rented
     * @param tokenId: the ID of the token
     */
    function isTokenRented(uint256 tokenId) external view returns (bool) {
        return rentals[tokenId].isActive;
    }

    /**
     * @dev Emergency function to handle late returns (owner only)
     * @param tokenId: the ID of the token
     */
    function forceEndRental(uint256 tokenId) external onlyOwner nonReentrant {
        Rental storage rental = rentals[tokenId];
        require(rental.isActive, "Rental is not active");
        require(block.timestamp > rental.endTime, "Rental period not expired");

        // Get late fee from NFT contract
        RentalNFT.ItemDetails memory item = rentalNFT.getItemDetails(tokenId);
        uint256 daysLate = (block.timestamp - rental.endTime) / 1 days;
        uint256 lateFee = uint256(item.lateFee) * daysLate;

        uint256 platformFee = (rental.rentalFee * _platformFeePercentage) / 100;
        uint256 lenderFee = rental.rentalFee - platformFee;

        // Deduct late fee from security deposit
        uint256 remainingDeposit = rental.securityDeposit > lateFee
            ? rental.securityDeposit - lateFee
            : 0;

        // Additional compensation to lender from security deposit
        uint256 additionalLenderFee = rental.securityDeposit - remainingDeposit;

        address lender = rental.lender;
        address renter = rental.renter;

        rental.isActive = false;
        rental.isReturned = true;

        // Update rental state in NFT contract
        rentalNFT.endRental(tokenId);

        // Transfer NFT back to lender
        rentalNFT.transferFrom(renter, lender, tokenId);

        // Handle payments with late fee adjustments
        require(
            usdc.transfer(lender, lenderFee + additionalLenderFee),
            "Lender transfer failed"
        );

        require(
            usdc.transfer(owner(), platformFee),
            "Platform transfer failed"
        );

        if (remainingDeposit > 0) {
            require(
                usdc.transfer(renter, remainingDeposit),
                "Renter transfer failed"
            );
        }

        emit RentalEnded(
            tokenId,
            lender,
            renter,
            lenderFee + additionalLenderFee,
            platformFee
        );
    }

    function getPlatformFee() external view returns (uint8) {
        return _platformFeePercentage;
    }

    function updatePlatformFee(uint8 newPlatformFee) external onlyOwner {
        require(newPlatformFee <= 100, "Platform fee cannot exceed 100%");
        _platformFeePercentage = newPlatformFee;
    }

    receive() external payable {}
}
