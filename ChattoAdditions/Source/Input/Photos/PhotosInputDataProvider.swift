/*
 The MIT License (MIT)

 Copyright (c) 2015-present Badoo Trading Limited.

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
*/

import PhotosUI

protocol PhotosInputDataProviderDelegate: class {
    func handlePhotosInpudDataProviderUpdate(_ dataProvider: PhotosInputDataProviderProtocol, updateBlock: @escaping () -> Void)
}

protocol PhotosInputDataProviderProtocol : class {
    weak var delegate: PhotosInputDataProviderDelegate? { get set }
    var count: Int { get }
    func requestPreviewImageAtIndex(_ index: Int, targetSize: CGSize, completion: @escaping (UIImage) -> Void) -> Int32
    func requestFullImageAtIndex(_ index: Int, completion: @escaping (UIImage?, String) -> Void)
    func cancelPreviewImageRequest(_ requestID: Int32)
}

class PhotosInputPlaceholderDataProvider: PhotosInputDataProviderProtocol {
    weak var delegate: PhotosInputDataProviderDelegate?

    let numberOfPlaceholders: Int

    init(numberOfPlaceholders: Int = 5) {
        self.numberOfPlaceholders = numberOfPlaceholders
    }

    var count: Int {
        return self.numberOfPlaceholders
    }

    func requestPreviewImageAtIndex(_ index: Int, targetSize: CGSize, completion: @escaping (UIImage) -> Void) -> Int32 {
        return 0
    }

    func requestFullImageAtIndex(_ index: Int, completion: @escaping (UIImage?, String) -> Void) {
    }

    func cancelPreviewImageRequest(_ requestID: Int32) {
    }
}

@objc
class PhotosInputDataProvider: NSObject, PhotosInputDataProviderProtocol, PHPhotoLibraryChangeObserver {
    weak var delegate: PhotosInputDataProviderDelegate?
    private var imageManager = PHCachingImageManager()
    private var fetchResult: PHFetchResult<PHAsset>!
    override init() {
        func fetchOptions(_ predicate: NSPredicate?) -> PHFetchOptions {
            let options = PHFetchOptions()
            options.sortDescriptors = [ NSSortDescriptor(key: "creationDate", ascending: false) ]
            options.predicate = predicate
            return options
        }

        if let userLibraryCollection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject {
            
            let predicateImage = NSPredicate(format: "mediaType = \(PHAssetMediaType.image.rawValue)")
            let predicateVideo = NSPredicate(format: "mediaType = \(PHAssetMediaType.video.rawValue)")
            let predicateOr = NSCompoundPredicate.init(type: .or, subpredicates: [predicateImage,predicateVideo])
            
            
            self.fetchResult = PHAsset.fetchAssets(in: userLibraryCollection, options: fetchOptions(predicateOr))
        } else {
            self.fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions(nil))
        }
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    var count: Int {
        return self.fetchResult.count
    }

    func requestPreviewImageAtIndex(_ index: Int, targetSize: CGSize, completion: @escaping (UIImage) -> Void) -> Int32 {
        assert(index >= 0 && index < self.fetchResult.count, "Index out of bounds")
        let asset = self.fetchResult[index]
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        return self.imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { (image, _) in
            if let image = image {
                completion(image)
            }
        }
    }

    func cancelPreviewImageRequest(_ requestID: Int32) {
        self.imageManager.cancelImageRequest(requestID)
    }

    func requestFullImageAtIndex(_ index: Int, completion: @escaping (UIImage?, String) -> Void) {
        assert(index >= 0 && index < self.fetchResult.count, "Index out of bounds")
        let asset = self.fetchResult[index]
        
        getAssetUrl(mPhasset: asset) { (url) in
            if asset.mediaType == .image {
                self.imageManager.requestImageData(for: asset, options: .none) { (data, _, _, _) -> Void in
                    if let data = data, let image = UIImage(data: data) {
                        // Save image as JPEG in temp location
                        if let jpegdata = UIImageJPEGRepresentation(image, 0.8) {
                            let fileName = String(format: "%@_%@", ProcessInfo.processInfo.globallyUniqueString, ".jpg")
                            let fileURL = NSURL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
                            try? jpegdata.write(to: fileURL!)
                            completion(image, fileURL!.absoluteString)
                        }
                    }
                }
            } else if asset.mediaType == .video {
                self.imageManager.requestExportSession(forVideo: asset, options: nil, exportPreset: AVAssetExportPresetPassthrough, resultHandler: { (exportSession, dict) in
                    if let exportSession = exportSession {
                        
                        let fileName = String(format: "%@_%@", ProcessInfo.processInfo.globallyUniqueString, ".mp4")
                        let mediaUrl = NSURL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)

                        exportSession.outputURL = mediaUrl
                        exportSession.outputFileType = AVFileType.mp4
                        exportSession.shouldOptimizeForNetworkUse = false
                        
                        /*
                        let start = CMTimeMakeWithSeconds(0.0, 0)
                        let range = CMTimeRange(start: start, duration: avAsset.duration)
                        exportSession.timeRange = range
                        */
                        
                        exportSession.exportAsynchronously{() -> Void in
                            switch exportSession.status{
                            case .failed:
                                print("\(exportSession.error!)")
                            case .cancelled:
                                print("Export cancelled")
                            case .completed:
                                print(exportSession.outputURL ?? "")
                                if let outputURL = exportSession.outputURL {
                                    completion(nil, outputURL.absoluteString)
                                }
                            default:
                                break
                            }
                            
                        }
                    }
                    
                })
                
                
            }
        }
        
    }

    // MARK: PHPhotoLibraryChangeObserver

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Photos may call this method on a background queue; switch to the main queue to update the UI.
        DispatchQueue.main.async { [weak self]  in
            guard let sSelf = self else { return }

            if let changeDetails = changeInstance.changeDetails(for: sSelf.fetchResult as! PHFetchResult<PHObject>) {
                let updateBlock = { () -> Void in
                    self?.fetchResult = changeDetails.fetchResultAfterChanges as! PHFetchResult<PHAsset>
                }
                sSelf.delegate?.handlePhotosInpudDataProviderUpdate(sSelf, updateBlock: updateBlock)
            }
        }
    }
    
    
    func getAssetUrl(mPhasset: PHAsset, completionHandler: @escaping ((_ responseURL : NSURL?) -> Void)){
        
        if mPhasset.mediaType == .image {
            let options: PHContentEditingInputRequestOptions = PHContentEditingInputRequestOptions()
            options.canHandleAdjustmentData = {(adjustmeta: PHAdjustmentData) -> Bool in
                return true
            }
            mPhasset.requestContentEditingInput(with: options, completionHandler: {(contentEditingInput: PHContentEditingInput?, info: [AnyHashable : Any]) -> Void in
                completionHandler(contentEditingInput!.fullSizeImageURL! as NSURL)
            })
        } else if mPhasset.mediaType == .video {
            let options: PHVideoRequestOptions = PHVideoRequestOptions()
            options.version = .original
            PHImageManager.default().requestAVAsset(forVideo: mPhasset, options: options, resultHandler: {(asset: AVAsset?, audioMix: AVAudioMix?, info: [AnyHashable : Any]?) -> Void in
                
                if let urlAsset = asset as? AVURLAsset {
                    let localVideoUrl : NSURL = urlAsset.url as NSURL
                    completionHandler(localVideoUrl)
                } else {
                    completionHandler(nil)
                }
            })
        }
        
    }
}

class PhotosInputWithPlaceholdersDataProvider: PhotosInputDataProviderProtocol, PhotosInputDataProviderDelegate {
    weak var delegate: PhotosInputDataProviderDelegate?
    private let photosDataProvider: PhotosInputDataProviderProtocol
    private let placeholdersDataProvider: PhotosInputDataProviderProtocol

    init(photosDataProvider: PhotosInputDataProviderProtocol, placeholdersDataProvider: PhotosInputDataProviderProtocol) {
        self.photosDataProvider = photosDataProvider
        self.placeholdersDataProvider = placeholdersDataProvider
        self.photosDataProvider.delegate = self
    }

    var count: Int {
        return max(self.photosDataProvider.count, self.placeholdersDataProvider.count)
    }

    func requestPreviewImageAtIndex(_ index: Int, targetSize: CGSize, completion: @escaping (UIImage) -> Void) -> Int32 {
        if index < self.photosDataProvider.count {
            return self.photosDataProvider.requestPreviewImageAtIndex(index, targetSize: targetSize, completion: completion)
        } else {
            return self.placeholdersDataProvider.requestPreviewImageAtIndex(index, targetSize: targetSize, completion: completion)
        }
    }

    func requestFullImageAtIndex(_ index: Int, completion: @escaping (UIImage?, String) -> Void) {
        if index < self.photosDataProvider.count {
            return self.photosDataProvider.requestFullImageAtIndex(index, completion: completion)
        } else {
            return self.placeholdersDataProvider.requestFullImageAtIndex(index, completion: completion)
        }
    }

    func cancelPreviewImageRequest(_ requestID: Int32) {
        return self.photosDataProvider.cancelPreviewImageRequest(requestID)
    }

    // MARK: PhotosInputDataProviderDelegate

    func handlePhotosInpudDataProviderUpdate(_ dataProvider: PhotosInputDataProviderProtocol, updateBlock: @escaping () -> Void) {
        self.delegate?.handlePhotosInpudDataProviderUpdate(self, updateBlock: updateBlock)
    }
}
