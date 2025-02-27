{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

{- HLINT ignore "Avoid lambda using `infix`" -}

-- | Cardano addresses: payment and stake addresses.
--
module Cardano.Api.Address (
    -- * Payment addresses
    -- | Constructing and inspecting normal payment addresses
    Address(..),

    -- ** Byron addresses
    ByronAddr,
    makeByronAddress,

    -- ** Shelley addresses
    ShelleyAddr,
    makeShelleyAddress,
    PaymentCredential(..),
    StakeAddressReference(..),
    StakeAddressPointer(..),

    -- ** Addresses in any era
    AddressAny(..),
    lexPlausibleAddressString,
    parseAddressAny,

    -- ** Addresses in specific eras
    AddressInEra(..),
    AddressTypeInEra(..),
    byronAddressInEra,
    shelleyAddressInEra,
    anyAddressInShelleyBasedEra,
    anyAddressInEra,
    toAddressAny,
    makeByronAddressInEra,
    makeShelleyAddressInEra,

    -- * Stake addresses
    -- | Constructing and inspecting stake addresses
    StakeAddress(..),
    StakeCredential(..),
    makeStakeAddress,
    StakeKey,
    StakeExtendedKey,

    -- * Conversion functions
    shelleyPayAddrToPlutusPubKHash,

    -- * Internal conversion functions
    toShelleyAddr,
    toShelleyStakeAddr,
    toShelleyStakeCredential,
    fromShelleyAddr,
    fromShelleyAddrIsSbe,
    fromShelleyAddrToAny,
    fromShelleyPaymentCredential,
    fromShelleyStakeAddr,
    fromShelleyStakeCredential,
    fromShelleyStakeReference,

    -- * Serialising addresses
    SerialiseAddress(..),

    -- * Data family instances
    AsType(AsByronAddr, AsShelleyAddr, AsByronAddress, AsShelleyAddress,
           AsAddress, AsAddressAny, AsAddressInEra, AsStakeAddress),

    -- * Helpers
    isKeyAddress
  ) where

import           Prelude

import           Control.Applicative ((<|>))
import           Data.Aeson (FromJSON (..), ToJSON (..), withText, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Base58 as Base58
import           Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Text.Parsec as Parsec
import qualified Text.Parsec.String as Parsec

import qualified Cardano.Chain.Common as Byron
import qualified Cardano.Ledger.Address as Shelley
import qualified Cardano.Ledger.Alonzo.TxInfo as Alonzo
import qualified Cardano.Ledger.BaseTypes as Shelley
import qualified Cardano.Ledger.Credential as Shelley
import           Cardano.Ledger.Crypto (StandardCrypto)
import qualified Plutus.V1.Ledger.Api as Plutus

import           Cardano.Api.EraCast
import           Cardano.Api.Eras
import           Cardano.Api.Hash
import           Cardano.Api.HasTypeProxy
import           Cardano.Api.Key
import           Cardano.Api.KeysByron
import           Cardano.Api.KeysShelley
import           Cardano.Api.NetworkId
import           Cardano.Api.Script
import           Cardano.Api.SerialiseBech32
import           Cardano.Api.SerialiseRaw
import           Cardano.Api.Utils
import           Control.DeepSeq (NFData(..), deepseq)



-- ----------------------------------------------------------------------------
-- Address Serialisation
--

-- | Address serialisation uses different serialisation formats for different
-- kinds of addresses, so it needs its own class.
--
-- In particular, Byron addresses are typically formatted in base 58, while
-- Shelley addresses (payment and stake) are formatted using Bech32.
--
class HasTypeProxy addr => SerialiseAddress addr where

    serialiseAddress :: addr -> Text

    deserialiseAddress :: AsType addr -> Text -> Maybe addr
    -- TODO: consider adding data AddressDecodeError


-- ----------------------------------------------------------------------------
-- Payment address types
--

-- | A type used as a tag to distinguish Byron addresses.
data ByronAddr

-- | A type used as a tag to distinguish Shelley addresses.
data ShelleyAddr

instance HasTypeProxy ByronAddr where
    data AsType ByronAddr = AsByronAddr
    proxyToAsType _ = AsByronAddr

instance HasTypeProxy ShelleyAddr where
    data AsType ShelleyAddr = AsShelleyAddr
    proxyToAsType _ = AsShelleyAddr


-- ----------------------------------------------------------------------------
-- Payment addresses
--

-- | Addresses are used as locations where assets live. The address determines
-- the rights needed to spend assets at the address: in particular holding some
-- signing key or being able to satisfy the conditions of a script.
--
-- There are currently two types of address:
--
-- * Byron addresses, which use the type tag 'ByronAddr'; and
-- * Shelley addresses, which use the type tag 'ShelleyAddr'. Notably, Shelley
--   addresses support scripts and stake delegation.
--
-- The /address type/ is subtly from the /ledger era/ in which each
-- address type is valid: while Byron addresses are the only choice in the
-- Byron era, the Shelley era and all subsequent eras support both Byron and
-- Shelley addresses. The 'Address' type param only says the type of the address
-- (either Byron or Shelley). The 'AddressInEra' type connects the address type
-- with the era in which it is supported.
--
data Address addrtype where

     -- | Byron addresses were the only supported address type in the original
     -- Byron era.
     --
     ByronAddress
       :: Byron.Address
       -> Address ByronAddr

     -- | Shelley addresses allow delegation. Shelley addresses were introduced
     -- in Shelley era and are thus supported from the Shelley era onwards
     --
     ShelleyAddress
       :: Shelley.Network
       -> Shelley.PaymentCredential StandardCrypto
       -> Shelley.StakeReference    StandardCrypto
       -> Address ShelleyAddr
       -- Note that the two ledger credential types here are parametrised by
       -- the era, but in fact this is a phantom type parameter and they are
       -- the same for all eras. See 'toShelleyAddr' below.

deriving instance Eq   (Address addrtype)
deriving instance Ord  (Address addrtype)
deriving instance Show (Address addrtype)

instance NFData (Address addrtype) where
  rnf = \case
    ByronAddress address -> deepseq address ()
    ShelleyAddress n pc sr -> deepseq (deepseq (deepseq n pc) sr) ()

instance HasTypeProxy addrtype => HasTypeProxy (Address addrtype) where
    data AsType (Address addrtype) = AsAddress (AsType addrtype)
    proxyToAsType _ = AsAddress (proxyToAsType (Proxy :: Proxy addrtype))

pattern AsByronAddress :: AsType (Address ByronAddr)
pattern AsByronAddress   = AsAddress AsByronAddr
{-# COMPLETE AsByronAddress #-}

pattern AsShelleyAddress :: AsType (Address ShelleyAddr)
pattern AsShelleyAddress = AsAddress AsShelleyAddr
{-# COMPLETE AsShelleyAddress #-}

instance SerialiseAsRawBytes (Address ByronAddr) where
    serialiseToRawBytes (ByronAddress addr) =
        Shelley.serialiseAddr
      . Shelley.AddrBootstrap
      . Shelley.BootstrapAddress
      $ addr

    deserialiseFromRawBytes (AsAddress AsByronAddr) bs =
        case Shelley.deserialiseAddr bs :: Maybe (Shelley.Addr StandardCrypto) of
          Nothing             -> Nothing
          Just Shelley.Addr{} -> Nothing
          Just (Shelley.AddrBootstrap (Shelley.BootstrapAddress addr)) ->
            Just (ByronAddress addr)

instance SerialiseAsRawBytes (Address ShelleyAddr) where
    serialiseToRawBytes (ShelleyAddress nw pc scr) =
        Shelley.serialiseAddr (Shelley.Addr nw pc scr)

    deserialiseFromRawBytes (AsAddress AsShelleyAddr) bs =
        case Shelley.deserialiseAddr bs of
          Nothing                       -> Nothing
          Just Shelley.AddrBootstrap{}  -> Nothing
          Just (Shelley.Addr nw pc scr) -> Just (ShelleyAddress nw pc scr)

instance SerialiseAsBech32 (Address ShelleyAddr) where
    bech32PrefixFor (ShelleyAddress Shelley.Mainnet _ _) = "addr"
    bech32PrefixFor (ShelleyAddress Shelley.Testnet _ _) = "addr_test"

    bech32PrefixesPermitted (AsAddress AsShelleyAddr) = ["addr", "addr_test"]


instance SerialiseAddress (Address ByronAddr) where
    serialiseAddress addr@ByronAddress{} =
         Text.decodeLatin1
       . Base58.encodeBase58 Base58.bitcoinAlphabet
       . serialiseToRawBytes
       $ addr

    deserialiseAddress (AsAddress AsByronAddr) txt = do
      bs <- Base58.decodeBase58 Base58.bitcoinAlphabet (Text.encodeUtf8 txt)
      deserialiseFromRawBytes (AsAddress AsByronAddr) bs

instance SerialiseAddress (Address ShelleyAddr) where
    serialiseAddress addr@ShelleyAddress{} =
      serialiseToBech32 addr

    deserialiseAddress (AsAddress AsShelleyAddr) t =
      either (const Nothing) Just $
      deserialiseFromBech32 (AsAddress AsShelleyAddr) t


makeByronAddress :: NetworkId
                 -> VerificationKey ByronKey
                 -> Address ByronAddr
makeByronAddress nw (ByronVerificationKey vk) =
    ByronAddress $
      Byron.makeVerKeyAddress
        (toByronNetworkMagic nw)
        vk


makeShelleyAddress :: NetworkId
                   -> PaymentCredential
                   -> StakeAddressReference
                   -> Address ShelleyAddr
makeShelleyAddress nw pc scr =
    ShelleyAddress
      (toShelleyNetwork nw)
      (toShelleyPaymentCredential pc)
      (toShelleyStakeReference scr)


-- ----------------------------------------------------------------------------
-- Either type of address
--

-- | Either a Byron address or a Shelley address.
--
-- Sometimes we need to be able to work with either of the two types of
-- address (Byron or Shelley addresses), but without reference to an era in
-- which the address will be used. This type serves that purpose.
--
data AddressAny = AddressByron   !(Address ByronAddr)
                | AddressShelley !(Address ShelleyAddr)
  deriving (Eq, Ord, Show)

instance HasTypeProxy AddressAny where
    data AsType AddressAny = AsAddressAny
    proxyToAsType _ = AsAddressAny

instance SerialiseAsRawBytes AddressAny where
    serialiseToRawBytes (AddressByron   addr) = serialiseToRawBytes addr
    serialiseToRawBytes (AddressShelley addr) = serialiseToRawBytes addr

    deserialiseFromRawBytes AsAddressAny bs =
      case Shelley.deserialiseAddr bs of
        Nothing -> Nothing
        Just (Shelley.AddrBootstrap (Shelley.BootstrapAddress addr)) ->
          Just (AddressByron (ByronAddress addr))

        Just (Shelley.Addr nw pc scr) ->
          Just (AddressShelley (ShelleyAddress nw pc scr))

instance SerialiseAddress AddressAny where
    serialiseAddress (AddressByron   addr) = serialiseAddress addr
    serialiseAddress (AddressShelley addr) = serialiseAddress addr

    deserialiseAddress AsAddressAny t =
          (AddressByron   <$> deserialiseAddress (AsAddress AsByronAddr)   t)
      <|> (AddressShelley <$> deserialiseAddress (AsAddress AsShelleyAddr) t)


fromShelleyAddrToAny :: Shelley.Addr StandardCrypto -> AddressAny
fromShelleyAddrToAny (Shelley.AddrBootstrap (Shelley.BootstrapAddress addr)) =
  AddressByron $ ByronAddress addr
fromShelleyAddrToAny (Shelley.Addr nw pc scr) =
  AddressShelley $ ShelleyAddress nw pc scr

-- ----------------------------------------------------------------------------
-- Addresses in the context of a ledger era
--

-- | An 'Address' that can be used in a particular ledger era.
--
-- All current ledger eras support Byron addresses. Shelley addresses are
-- supported in the 'ShelleyEra' and later eras.
--
data AddressInEra era where
     AddressInEra :: AddressTypeInEra addrtype era
                  -> Address addrtype
                  -> AddressInEra era

instance NFData (AddressInEra era) where
  rnf (AddressInEra t a) = deepseq (deepseq t a) ()

instance IsCardanoEra era => ToJSON (AddressInEra era) where
  toJSON = Aeson.String . serialiseAddress

instance IsShelleyBasedEra era => FromJSON (AddressInEra era) where
  parseJSON = withText "AddressInEra" $ \txt -> do
    addressAny <- runParsecParser parseAddressAny txt
    pure $ anyAddressInShelleyBasedEra addressAny

instance EraCast AddressInEra where
  eraCast toEra' (AddressInEra addressTypeInEra address) = AddressInEra
    <$> eraCast toEra' addressTypeInEra
    <*> pure address

parseAddressAny :: Parsec.Parser AddressAny
parseAddressAny = do
    str <- lexPlausibleAddressString
    case deserialiseAddress AsAddressAny str of
      Nothing   -> fail $ "invalid address: " <> Text.unpack str
      Just addr -> pure addr

lexPlausibleAddressString :: Parsec.Parser Text
lexPlausibleAddressString =
    Text.pack <$> Parsec.many1 (Parsec.satisfy isPlausibleAddressChar)
  where
    -- Covers both base58 and bech32 (with constrained prefixes)
    isPlausibleAddressChar c =
         isAsciiLower c
      || isAsciiUpper c
      || isDigit c
      || c == '_'

instance Eq (AddressInEra era) where
  (==) (AddressInEra ByronAddressInAnyEra addr1)
       (AddressInEra ByronAddressInAnyEra addr2) = addr1 == addr2

  (==) (AddressInEra ShelleyAddressInEra{} addr1)
       (AddressInEra ShelleyAddressInEra{} addr2) = addr1 == addr2

  (==) (AddressInEra ByronAddressInAnyEra _)
       (AddressInEra ShelleyAddressInEra{} _) = False

  (==) (AddressInEra ShelleyAddressInEra{} _)
       (AddressInEra ByronAddressInAnyEra _) = False

deriving instance Show (AddressInEra era)

data AddressTypeInEra addrtype era where

     ByronAddressInAnyEra :: AddressTypeInEra ByronAddr era

     ShelleyAddressInEra  :: ShelleyBasedEra era
                          -> AddressTypeInEra ShelleyAddr era

deriving instance Show (AddressTypeInEra addrtype era)

instance NFData (AddressTypeInEra addrtype era) where
  rnf = \case
    ByronAddressInAnyEra -> ()
    ShelleyAddressInEra sbe -> deepseq sbe ()

instance HasTypeProxy era => HasTypeProxy (AddressInEra era) where
    data AsType (AddressInEra era) = AsAddressInEra (AsType era)
    proxyToAsType _ = AsAddressInEra (proxyToAsType (Proxy :: Proxy era))

instance IsCardanoEra era => SerialiseAsRawBytes (AddressInEra era) where

    serialiseToRawBytes (AddressInEra ByronAddressInAnyEra addr) =
      serialiseToRawBytes addr

    serialiseToRawBytes (AddressInEra ShelleyAddressInEra{} addr) =
      serialiseToRawBytes addr

    deserialiseFromRawBytes _ bs =
      anyAddressInEra cardanoEra =<< deserialiseFromRawBytes AsAddressAny bs

instance IsCardanoEra era => SerialiseAddress (AddressInEra era) where
    serialiseAddress (AddressInEra ByronAddressInAnyEra addr) =
      serialiseAddress addr

    serialiseAddress (AddressInEra ShelleyAddressInEra{} addr) =
      serialiseAddress addr

    deserialiseAddress _ t =
      anyAddressInEra cardanoEra =<< deserialiseAddress AsAddressAny t

instance EraCast (AddressTypeInEra addrtype) where
  eraCast toEra' v = case v of
    ByronAddressInAnyEra -> pure ByronAddressInAnyEra
    ShelleyAddressInEra previousEra ->
      case cardanoEraStyle toEra' of
        LegacyByronEra -> Left $ EraCastError v (shelleyBasedToCardanoEra previousEra) toEra'
        ShelleyBasedEra newSbe -> Right $ ShelleyAddressInEra newSbe

byronAddressInEra :: Address ByronAddr -> AddressInEra era
byronAddressInEra = AddressInEra ByronAddressInAnyEra


shelleyAddressInEra :: IsShelleyBasedEra era
                    => Address ShelleyAddr -> AddressInEra era
shelleyAddressInEra = AddressInEra (ShelleyAddressInEra shelleyBasedEra)


anyAddressInShelleyBasedEra :: IsShelleyBasedEra era
                            => AddressAny -> AddressInEra era
anyAddressInShelleyBasedEra (AddressByron   addr) = byronAddressInEra addr
anyAddressInShelleyBasedEra (AddressShelley addr) = shelleyAddressInEra addr


anyAddressInEra :: CardanoEra era
                -> AddressAny
                -> Maybe (AddressInEra era)
anyAddressInEra _ (AddressByron addr) =
    Just (AddressInEra ByronAddressInAnyEra addr)

anyAddressInEra era (AddressShelley addr) =
    case cardanoEraStyle era of
      LegacyByronEra       -> Nothing
      ShelleyBasedEra era' -> Just (AddressInEra (ShelleyAddressInEra era') addr)

toAddressAny :: Address addr -> AddressAny
toAddressAny a@ShelleyAddress{} = AddressShelley a
toAddressAny a@ByronAddress{}   = AddressByron a

makeByronAddressInEra :: NetworkId
                      -> VerificationKey ByronKey
                      -> AddressInEra era
makeByronAddressInEra nw vk =
    byronAddressInEra (makeByronAddress nw vk)


makeShelleyAddressInEra :: IsShelleyBasedEra era
                        => NetworkId
                        -> PaymentCredential
                        -> StakeAddressReference
                        -> AddressInEra era
makeShelleyAddressInEra nw pc scr =
    shelleyAddressInEra (makeShelleyAddress nw pc scr)


-- ----------------------------------------------------------------------------
-- Stake addresses
--

data StakeAddress where

     StakeAddress
       :: Shelley.Network
       -> Shelley.StakeCredential StandardCrypto
       -> StakeAddress
  deriving (Eq, Ord, Show)

data PaymentCredential
       = PaymentCredentialByKey    (Hash PaymentKey)
       | PaymentCredentialByScript  ScriptHash
  deriving (Eq, Ord, Show)

data StakeCredential
       = StakeCredentialByKey    (Hash StakeKey)
       | StakeCredentialByScript  ScriptHash
  deriving (Eq, Ord, Show)

instance ToJSON StakeCredential where
  toJSON =
    Aeson.object
      . \case
        StakeCredentialByKey keyHash ->
          ["stakingKeyHash" .= serialiseToRawBytesHexText keyHash]
        StakeCredentialByScript scriptHash ->
          ["stakingScriptHash" .= serialiseToRawBytesHexText scriptHash]

data StakeAddressReference
       = StakeAddressByValue   StakeCredential
       | StakeAddressByPointer StakeAddressPointer
       | NoStakeAddress
  deriving (Eq, Show)

newtype StakeAddressPointer = StakeAddressPointer
  { unStakeAddressPointer :: Shelley.Ptr
  }
  deriving (Eq, Show)

instance HasTypeProxy StakeAddress where
    data AsType StakeAddress = AsStakeAddress
    proxyToAsType _ = AsStakeAddress


instance SerialiseAsRawBytes StakeAddress where
    serialiseToRawBytes (StakeAddress nw sc) =
        Shelley.serialiseRewardAcnt (Shelley.RewardAcnt nw sc)

    deserialiseFromRawBytes AsStakeAddress bs =
        case Shelley.deserialiseRewardAcnt bs of
          Nothing -> Nothing
          Just (Shelley.RewardAcnt nw sc) -> Just (StakeAddress nw sc)


instance SerialiseAsBech32 StakeAddress where
    bech32PrefixFor (StakeAddress Shelley.Mainnet _) = "stake"
    bech32PrefixFor (StakeAddress Shelley.Testnet _) = "stake_test"

    bech32PrefixesPermitted AsStakeAddress = ["stake", "stake_test"]


instance SerialiseAddress StakeAddress where
    serialiseAddress addr@StakeAddress{} =
      serialiseToBech32 addr

    deserialiseAddress AsStakeAddress t =
      either (const Nothing) Just $
      deserialiseFromBech32 AsStakeAddress t

instance ToJSON StakeAddress where
  toJSON s = Aeson.String $ serialiseAddress s

instance FromJSON StakeAddress where
  parseJSON = withText "StakeAddress" $ \str ->
    case deserialiseAddress AsStakeAddress str of
      Nothing ->
        fail $ "Error while deserialising StakeAddress: " <> Text.unpack str
      Just sAddr -> pure sAddr

makeStakeAddress :: NetworkId
                 -> StakeCredential
                 -> StakeAddress
makeStakeAddress nw sc =
    StakeAddress
      (toShelleyNetwork nw)
      (toShelleyStakeCredential sc)

-- ----------------------------------------------------------------------------
-- Helpers
--

-- | Is the UTxO at the address only spendable via a key witness.
isKeyAddress :: AddressInEra era -> Bool
isKeyAddress (AddressInEra ByronAddressInAnyEra _) = True
isKeyAddress (AddressInEra (ShelleyAddressInEra _) (ShelleyAddress _ pCred _)) =
  case fromShelleyPaymentCredential pCred of
    PaymentCredentialByKey _ -> True
    PaymentCredentialByScript _ -> False

-- | Converts a Shelley payment address to a Plutus public key hash.
shelleyPayAddrToPlutusPubKHash :: Address ShelleyAddr -> Maybe Plutus.PubKeyHash
shelleyPayAddrToPlutusPubKHash (ShelleyAddress _ payCred _) =
  case payCred of
    Shelley.ScriptHashObj _ -> Nothing
    Shelley.KeyHashObj kHash -> Just $ Alonzo.transKeyHash kHash

-- ----------------------------------------------------------------------------
-- Internal conversion functions
--

toShelleyAddr :: AddressInEra era -> Shelley.Addr StandardCrypto
toShelleyAddr (AddressInEra ByronAddressInAnyEra (ByronAddress addr)) =
    Shelley.AddrBootstrap (Shelley.BootstrapAddress addr)
toShelleyAddr (AddressInEra (ShelleyAddressInEra _)
                            (ShelleyAddress nw pc scr)) =
    Shelley.Addr nw pc scr

toShelleyStakeAddr :: StakeAddress -> Shelley.RewardAcnt StandardCrypto
toShelleyStakeAddr (StakeAddress nw sc) =
    Shelley.RewardAcnt {
      Shelley.getRwdNetwork = nw,
      Shelley.getRwdCred    = sc
    }

toShelleyPaymentCredential :: PaymentCredential
                           -> Shelley.PaymentCredential StandardCrypto
toShelleyPaymentCredential (PaymentCredentialByKey (PaymentKeyHash kh)) =
    Shelley.KeyHashObj kh
toShelleyPaymentCredential (PaymentCredentialByScript sh) =
    Shelley.ScriptHashObj (toShelleyScriptHash sh)

toShelleyStakeCredential :: StakeCredential
                         -> Shelley.StakeCredential StandardCrypto
toShelleyStakeCredential (StakeCredentialByKey (StakeKeyHash kh)) =
    Shelley.KeyHashObj kh
toShelleyStakeCredential (StakeCredentialByScript sh) =
    Shelley.ScriptHashObj (toShelleyScriptHash sh)

toShelleyStakeReference :: StakeAddressReference
                        -> Shelley.StakeReference StandardCrypto
toShelleyStakeReference (StakeAddressByValue stakecred) =
    Shelley.StakeRefBase (toShelleyStakeCredential stakecred)
toShelleyStakeReference (StakeAddressByPointer ptr) =
    Shelley.StakeRefPtr (unStakeAddressPointer ptr)
toShelleyStakeReference  NoStakeAddress =
    Shelley.StakeRefNull

fromShelleyAddrIsSbe :: IsShelleyBasedEra era
                     => Shelley.Addr StandardCrypto -> AddressInEra era
fromShelleyAddrIsSbe (Shelley.AddrBootstrap (Shelley.BootstrapAddress addr)) =
  AddressInEra ByronAddressInAnyEra (ByronAddress addr)

fromShelleyAddrIsSbe (Shelley.Addr nw pc scr) =
  AddressInEra
    (ShelleyAddressInEra shelleyBasedEra)
    (ShelleyAddress nw pc scr)

fromShelleyAddr
  :: ShelleyBasedEra era
  -> Shelley.Addr StandardCrypto
  -> AddressInEra era
fromShelleyAddr _ (Shelley.AddrBootstrap (Shelley.BootstrapAddress addr)) =
    AddressInEra ByronAddressInAnyEra (ByronAddress addr)

fromShelleyAddr sBasedEra (Shelley.Addr nw pc scr) =
    AddressInEra
      (ShelleyAddressInEra sBasedEra)
      (ShelleyAddress nw pc scr)

fromShelleyStakeAddr :: Shelley.RewardAcnt StandardCrypto -> StakeAddress
fromShelleyStakeAddr (Shelley.RewardAcnt nw sc) = StakeAddress nw sc

fromShelleyStakeCredential :: Shelley.StakeCredential StandardCrypto
                           -> StakeCredential
fromShelleyStakeCredential (Shelley.KeyHashObj kh) =
    StakeCredentialByKey (StakeKeyHash kh)
fromShelleyStakeCredential (Shelley.ScriptHashObj sh) =
    StakeCredentialByScript (fromShelleyScriptHash sh)

fromShelleyPaymentCredential :: Shelley.PaymentCredential StandardCrypto
                             -> PaymentCredential
fromShelleyPaymentCredential (Shelley.KeyHashObj kh) =
  PaymentCredentialByKey (PaymentKeyHash kh)
fromShelleyPaymentCredential (Shelley.ScriptHashObj sh) =
  PaymentCredentialByScript (ScriptHash sh)

fromShelleyStakeReference :: Shelley.StakeReference StandardCrypto
                          -> StakeAddressReference
fromShelleyStakeReference (Shelley.StakeRefBase stakecred) =
  StakeAddressByValue (fromShelleyStakeCredential stakecred)
fromShelleyStakeReference (Shelley.StakeRefPtr ptr) =
  StakeAddressByPointer (StakeAddressPointer ptr)
fromShelleyStakeReference Shelley.StakeRefNull =
  NoStakeAddress

