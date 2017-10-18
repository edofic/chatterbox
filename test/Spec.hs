import           System.Random (mkStdGen)
import           Test.Hspec
import           Test.QuickCheck (property)
import qualified Control.Distributed.Process as P
import qualified Data.Map as Map
import qualified Data.Set as Set

import Lib

main :: IO ()
main = hspec $ do
  describe "Lib.sumUpMessagesSuffix" $ do
    it "preserves input for empty suffix" $
      property $ \prefixCount prefixSum ->
        sumUpMessagesSuffix prefixCount prefixSum Set.empty == (prefixCount, prefixSum)

    it "counts the elements" $
      property $ \numbers ->
        let msgs = Set.fromList $ (\n -> (0, n)) `map` numbers
        in fromIntegral (fst (sumUpMessagesSuffix 0 0 msgs)) == Set.size msgs

    it "computes the scalar product of the values" $ do
      let msgs = Set.fromList [(2, 8), (5, 5), (0, 1), (1, 6)]
      snd (sumUpMessagesSuffix 0 0 msgs) `shouldBe` 57

  describe "Lib.compact" $ do
    it "does nothing for non-running" $ do
      let connecting = Connecting Set.empty
      compact connecting `shouldBe` connecting
      compact Quitted `shouldBe` Quitted

    it "does nothing when minimum timestamp is too soon" $ do
      let state = emptyRunning { received = Set.fromList [(1, 2), (2, 5)]
                               , latest = Map.fromList [(nodeId1, 0), (nodeId2, 3)]
                               }
      compact state `shouldBe` state

    it "compacts before the minimum timestamp" $ do
      let state = emptyRunning { received = Set.fromList [(6, 5), (8, 25), (10, 8)]
                               , latest = Map.fromList [(nodeId1, 9), (nodeId2, 10)]
                               , prefix = Prefix 5 72 5
                               }
          state' = state { received = Set.fromList [(10, 8)]
                         , latest = Map.fromList [(nodeId1, 9), (nodeId2, 10)]
                         , prefix = Prefix 7 277 5
                         }
      compact state `shouldBe` state'
      compact (compact state) `shouldBe` state'


emptyRunning :: AppState
emptyRunning = Running { msgGen = emptyGen
                       , buffer = Map.empty
                       , received = Set.empty
                       , latest = Map.empty
                       , prefix = Prefix 0 0 0
                       , sendingTimestamp = 0
                       , stopping = False
                       , acked = Set.empty
                       }


emptyGen :: MsgGen
emptyGen = MsgGen 1 $ mkStdGen 1


nodeId1, nodeId2 :: P.NodeId
nodeId1 = packPeer "nid1"
nodeId2 = packPeer "nid2"
