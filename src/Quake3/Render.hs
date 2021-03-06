{-# language RecordWildCards #-}

module Quake3.Render
  ( Resources( bsp )
  , initResources
  , renderToFrameBuffer
  , updateFromModel
  ) where

-- base
import Debug.Trace
import Control.Monad ( guard, when )
import Control.Monad.IO.Class ( MonadIO, liftIO )
import Data.Coerce ( coerce )
import Data.Foldable ( foldMap, for_ )
import qualified Foreign.C

-- contravariant
import Data.Functor.Contravariant

-- linear
import Linear
  ( (!*!)
  , (^+^)
  , lookAt
  , perspective
  , transpose
  , M44
  , V2(..)
  , V3(..)
  , V4(..)
  )
import qualified Linear.Matrix as Matrix
import qualified Linear.Quaternion as Quaternion

-- managed
import Control.Monad.Managed ( MonadManaged )

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan ()
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
  ( vkCmdDrawIndexed
  , vkCmdDraw
  , VkCommandBuffer
  , VkFramebuffer
  )
import qualified Graphics.Vulkan.Ext.VK_KHR_surface as Vulkan ()
import qualified Graphics.Vulkan.Ext.VK_KHR_swapchain as Vulkan ()

-- zero-to-quake-3
import qualified Quake3.BezierPatch
import Quake3.BSP
import Quake3.Context ( Context(..) )
import qualified Quake3.Model
import qualified Quake3.Vertex
import Vulkan.Buffer ( pokeBuffer )
import Vulkan.Buffer.IndexBuffer
  ( IndexBuffer
  , bindIndexBuffer
  , createIndexBuffer
  )
import Vulkan.Buffer.UniformBuffer ( UniformBuffer(..), createUniformBuffer )
import Vulkan.Buffer.VertexBuffer
  ( VertexBuffer
  , bindVertexBuffers
  , createVertexBuffer
  )
import Vulkan.CommandBuffer
  ( allocateCommandBuffer
  , withCommandBuffer
  )
import Vulkan.DescriptorSet
  ( bindDescriptorSets
  , updateDescriptorSet
  )
import Vulkan.Pipeline ( bindPipeline )
import qualified Vulkan.Poke
import Vulkan.RenderPass ( withRenderPass )


data Resources = Resources
  { vertexBuffer :: VertexBuffer VertexList
  , indexBuffer :: IndexBuffer MeshVertList

  , bezierVerts :: VertexBuffer [ Quake3.Vertex.Vertex ]
  , bezierIndices :: IndexBuffer [ Int ]
  , bezierDraw :: Int

  , uniformBuffer :: UniformBuffer ( M44 Foreign.C.CFloat )
  , bsp :: BSP -- TODO Should Render own this?
  }


initResources :: MonadManaged m => Context -> m Resources
initResources Context{..} = do
  bsp <-
    loadBSP "q3dm1.bsp"

  vertexBuffer <-
    createVertexBuffer
      physicalDevice
      device
      ( contramap vertexListBytes Vulkan.Poke.lazyBytestring )
      ( bspVertices bsp )

  indexBuffer <-
    createIndexBuffer
      physicalDevice
      device
      ( contramap meshVertListBytes Vulkan.Poke.lazyBytestring )
      ( bspMeshVerts bsp )

  uniformBuffer <-
    createUniformBuffer
      physicalDevice
      device
      Vulkan.Poke.storable
      ( modelViewProjection 0 0 )

  let
    bezierTriangles = do
      face <-
        bspFaces bsp

      guard ( faceType face == 2 )

      let
        controlPoints =
          map
            ( getVertex ( bspVertices bsp ) . fromIntegral )
            ( take
                ( fromIntegral ( faceNVertexes face ) )
                ( iterate succ ( faceVertex face ) )
            )

      let
        triangles =
          Quake3.BezierPatch.tessellate
            ( fromIntegral <$> uncurry V2 ( faceSize face ) )
            controlPoints

      triangles

    bezierVertices =
      concatMap ( foldMap pure ) bezierTriangles

  let
    bezierDraw =
      length bezierVertices

  liftIO $ do
    print ( map Quake3.Vertex.vPos bezierVertices )
    print bezierDraw

  bezierVerts <-
    createVertexBuffer
      physicalDevice
      device
      ( Vulkan.Poke.list Quake3.Vertex.poke )
      bezierVertices

  bezierIndices <-
    createIndexBuffer
      physicalDevice
      device
      ( Vulkan.Poke.list Vulkan.Poke.storable )
      [ 0 .. length bezierVertices ]

  updateDescriptorSet device descriptorSet uniformBuffer

  return Resources{..}


renderToFrameBuffer
  :: MonadManaged m
  => Context -> Resources -> Vulkan.VkFramebuffer -> m Vulkan.VkCommandBuffer
renderToFrameBuffer Context{..} Resources{..} framebuffer = do
  commandBuffer <-
    allocateCommandBuffer device commandPool

  withCommandBuffer commandBuffer $ do
    withRenderPass commandBuffer renderPass framebuffer extent $ do
      bindPipeline commandBuffer graphicsPipeline

      bindDescriptorSets commandBuffer pipelineLayout [ descriptorSet ]

      liftIO
        ( for_ ( bspFaces bsp ) $ \face ->
            case faceType face of
              n | n `elem` [ 1, 3 ] -> do
                bindVertexBuffers commandBuffer [ vertexBuffer ]

                bindIndexBuffer commandBuffer indexBuffer

                Vulkan.vkCmdDrawIndexed
                  commandBuffer
                  ( fromIntegral ( faceNMeshVerts face ) )
                  1
                  ( fromIntegral ( faceMeshVert face ) )
                  ( fromIntegral ( faceVertex face ) )
                  0

              2 -> do
                bindVertexBuffers commandBuffer [ bezierVerts ]

                bindIndexBuffer commandBuffer bezierIndices

                Vulkan.vkCmdDraw commandBuffer ( fromIntegral bezierDraw ) 1 0 0

              _ ->
                return ()
        )

  return commandBuffer


updateFromModel
  :: MonadIO m
  => Resources -> Quake3.Model.Quake3State -> m ()
updateFromModel Resources{..} Quake3.Model.Quake3State{..} = do
  liftIO ( print cameraPosition )
  pokeBuffer
    ( coerce uniformBuffer )
    ( modelViewProjection cameraPosition cameraAngles )


modelViewProjection
  :: V3 Foreign.C.CFloat
  -> V2 Foreign.C.CFloat
  -> M44 Foreign.C.CFloat
modelViewProjection cameraPosition ( V2 x y ) =
  let
    view =
      let
        orientation =
          Quaternion.axisAngle ( V3 0 1 0 ) x
            * Quaternion.axisAngle ( V3 1 0 0 ) y

        forward =
          Quaternion.rotate orientation ( V3 0 0 (-1) )

        up =
          Quaternion.rotate orientation ( V3 0 1 0 )

      in
      lookAt cameraPosition ( cameraPosition ^+^ forward ) up

    model =
      Matrix.identity

    projection =
      perspective ( pi / 2 ) ( 4 / 3 ) 0.1 10000

    correction =
      V4
        ( V4 (-1) 0    0     0     )
        ( V4 0    (-1) 0     0     )
        ( V4 0    0    (1/2) (1/2) )
        ( V4 0    0    0     1     )

  in
  transpose ( correction !*! projection !*! view !*! model )
