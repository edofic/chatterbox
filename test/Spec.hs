import           Test.Hspec
import           Test.QuickCheck (property)
import qualified Data.Set as Set

import Lib

main :: IO ()
main = hspec $ do
  describe "Lib.sumUpMessages" $ do
    it "counts the elements" $ do
      property $ \numbers ->
        let msgs = Set.fromList $ (\n -> (0, n)) `map` numbers
        in fromInteger (fst (sumUpMessages msgs)) == length numbers

    it "computes the scalar product of the values" $ do
      let msgs = Set.fromList [(2, 0.8), (5, 0.5), (0, 0.1), (1, 0.6)]
      snd (sumUpMessages msgs) `shouldBe` 5.7
