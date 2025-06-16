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

        require(
            usdc.transferFrom(msg.sender, address(this), totalCost),
            "USDC transfer failed"
        );
        rentalNFT.startRental(tokenId, msg.sender, duration);
    }

    /**
     * @dev End a rental for an item
     * @param tokenId: the ID of the item to return
     */
    //TODO: handle late fee
    function endRental(uint256 tokenId) external nonReentrant {
        Rental storage rental = rentals[tokenId];
        require(rental.isActive, "Rental is not active");
        require(rental.renter == msg.sender, "You are not the renter");

        uint256 platformFee = (rental.rentalFee * _platformFeePercentage) / 100;
        uint256 lenderFee = rental.rentalFee - platformFee;

        rental.isActive = false;
        rental.isReturned = true;

        rentalNFT.endRental(tokenId);

        require(
            usdc.transfer(rental.lender, lenderFee),
            "Lender transfer failed"
        );

        require(
            usdc.transfer(owner(), platformFee),
            "Platform transfer failed"
        );

        require(
            usdc.transfer(rental.renter, rental.securityDeposit),
            "Renter transfer failed"
        );
    }

    function getPlatformFee() external view returns (uint8) {
        return _platformFeePercentage;
    }

    function updatePlatformFee(uint8 newPlatformFee) external onlyOwner {
        _platformFeePercentage = newPlatformFee;
    }
}
