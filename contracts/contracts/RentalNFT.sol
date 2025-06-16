// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RentalNFT
 * @dev NFT contract for tokenizing household items that can be rented
 */
contract RentalNFT is ERC721, ERC721URIStorage, Ownable, ReentrancyGuard {
    uint256 private _nextTokenId;
    mapping(uint256 => ItemDetails) public itemDetails;
    mapping(address => uint256[]) public renterItems;

    struct ItemDetails {
        address renter;
        address lender;
        string uri;
        uint64 dailyFee;
        uint64 securityDeposit;
        bool isAvailable;
        uint256 rentalEndTime;
        uint64 lateFee;
    }

    constructor() ERC721("Idle2Earn", "I2E") Ownable(msg.sender) {}

    event ItemMinted(
        uint256 indexed tokenId,
        address indexed renter,
        string uri,
        uint64 dailyFee,
        uint64 securityDeposit
    );

    event ItemRented(
        uint256 indexed tokenId,
        address indexed renter,
        uint256 duration
    );

    event ItemReturned(
        uint256 indexed tokenId,
        address indexed renter,
        uint256 rentalEndTime
    );

    /**
     * @dev Mint a new item
     * @param to: the address to mint the item to
     * @param uri: the URI of the item
     * @param dailyFee: the daily fee of the item
     * @param securityDeposit: the security deposit of the item
     */
    function mintNFT(
        address to,
        string memory uri,
        uint64 dailyFee,
        uint64 securityDeposit,
        uint64 lateFee
    ) external nonReentrant returns (uint256) {
        require(dailyFee > 0, "Daily fee must be greater than 0");

        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        itemDetails[tokenId] = ItemDetails({
            renter: address(0),
            lender: ownerOf(tokenId),
            uri: uri,
            dailyFee: dailyFee,
            securityDeposit: securityDeposit,
            lateFee: lateFee,
            rentalEndTime: 0,
            isAvailable: true
        });

        emit ItemMinted(tokenId, to, uri, dailyFee, securityDeposit);

        return tokenId;
    }

    /**
     * @dev Start a rental for an item
     * @param tokenId: the ID of the item to rent
     * @param renter: the address of the renter
     * @param duration: the duration of the rental in days
     */
    function startRental(
        uint256 tokenId,
        address renter,
        uint32 duration
    ) external nonReentrant {
        ItemDetails storage item = itemDetails[tokenId];
        require(item.isAvailable, "Item is not available");
        require(renter != address(0), "Renter cannot be the zero address");
        require(duration > 0, "Duration must be greater than 0");

        item.renter = renter;
        item.isAvailable = false;
        item.rentalEndTime = block.timestamp + duration * 1 days;

        renterItems[renter].push(tokenId);

        transferFrom(item.lender, renter, tokenId);

        emit ItemRented(tokenId, renter, duration);
    }

    /**
     * @dev End a rental for an item
     * @param tokenId: the ID of the item to return
     */
    function endRental(uint256 tokenId) external nonReentrant {
        ItemDetails storage item = itemDetails[tokenId];
        require(item.renter != address(0), "Item is not rented");
        require(block.timestamp >= item.rentalEndTime, "Rental is not over");

        address renter = item.renter;

        item.renter = address(0);
        item.lender = address(0);
        item.isAvailable = true;
        item.rentalEndTime = 0;

        _removeRenterItem(renter, tokenId);

        transferFrom(renter, item.lender, tokenId);

        emit ItemReturned(tokenId, renter, item.rentalEndTime);
    }

    function getItemFees(
        uint256 tokenId
    ) external view returns (uint256, uint256) {
        ItemDetails memory item = itemDetails[tokenId];
        return (item.dailyFee, item.securityDeposit);
    }

    function getItemDetails(
        uint256 tokenId
    ) external view returns (ItemDetails memory) {
        ItemDetails memory item = itemDetails[tokenId];
        return item;
    }

    function _removeRenterItem(address renter, uint256 tokenId) internal {
        uint256[] storage items = renterItems[renter];
        for (uint256 i = 0; i < items.length; i++) {
            if (items[i] == tokenId) {
                items[i] = items[items.length - 1];
                items.pop();
                break;
            }
        }
    }

    // required by ERC721URIStorage
    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    // required by ERC721URIStorage
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
